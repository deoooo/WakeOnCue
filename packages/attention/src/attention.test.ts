import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import type { CueEvent } from "@wakeoncue/contracts";
import { deterministicId, replayCueEvents } from "@wakeoncue/core";

import {
  AttentionEngine,
  ObservationBroker,
  runStructuredJudge,
  type StructuredJudge,
} from "./index.js";

interface CorpusCase {
  id: string;
  occurredAt: string;
  segments: Array<{ text: string; isSubject: boolean }>;
  expectedWake: boolean;
}

const corpus = JSON.parse(
  readFileSync(resolve("packages/testing/fixtures/conversation-attention-corpus.v1.json"), "utf8"),
) as { cases: CorpusCase[] };

function eventFor(testCase: CorpusCase): CueEvent {
  return {
    specVersion: "wakeoncue.event/v1",
    eventId: deterministicId("evt", testCase.id),
    type: "conversation.finalized",
    source: { adapter: "fixture", sourceId: "fixture-source", providerRef: testCase.id },
    subject: "fixture-user",
    occurredAt: testCase.occurredAt,
    receivedAt: testCase.occurredAt,
    correlationId: testCase.id,
    confidence: 0.95,
    data: {
      conversation: {
        segments: testCase.segments.map((segment, index) => ({
          ...segment,
          speakerRef: segment.isSubject ? "subject" : "other",
          startSeconds: index * 5,
          endSeconds: index * 5 + 4,
        })),
        actionItems: [],
      },
    },
    evidenceRefs: [
      {
        uri: `fixture://attention/${testCase.id}`,
        mediaType: "text/plain",
        classification: "private",
      },
    ],
    privacy: { purpose: ["attention"], retention: "P7D" },
    idempotencyKey: `fixture:${testCase.id}`,
  };
}

describe("conversation attention", () => {
  it("meets the offline precision and recall gates with explainable decisions", async () => {
    const engine = new AttentionEngine();
    let truePositive = 0;
    let falsePositive = 0;
    let falseNegative = 0;

    for (const testCase of corpus.cases) {
      const event = eventFor(testCase);
      const episode = replayCueEvents([event]).episodes[0];
      if (!episode) throw new Error("Fixture projection missing");
      const evaluation = await engine.decide({
        episode,
        events: [event],
        sourceId: "fixture-source",
        cueType: "conversation.finalized",
        mode: "SHADOW",
        evaluationTime: testCase.occurredAt,
        timezoneOffsetMinutes: 480,
        quietHours: { startHour: 22, endHour: 7 },
        dailyBudget: { wakeLimit: 3, notifyLimit: 5, wakesUsed: 0, notificationsUsed: 0 },
        activeCooldownKeys: [],
      });
      const actualWake = evaluation.decision.decision === "WAKE_AGENT";
      if (actualWake && testCase.expectedWake) truePositive += 1;
      if (actualWake && !testCase.expectedWake) falsePositive += 1;
      if (!actualWake && testCase.expectedWake) falseNegative += 1;
      expect(evaluation.decision.reasonCodes.length, testCase.id).toBeGreaterThan(0);
      expect(evaluation.decision.evidenceRefs.length, testCase.id).toBeGreaterThan(0);
    }

    const precision = truePositive / (truePositive + falsePositive);
    const recall = truePositive / (truePositive + falseNegative);
    expect(precision).toBeGreaterThanOrEqual(0.9);
    expect(recall).toBeGreaterThanOrEqual(0.75);
  });

  it("enforces quiet hours, daily budget, cooldown, and source mode disposition", async () => {
    const event = eventFor(corpus.cases[0] as CorpusCase);
    const episode = replayCueEvents([event]).episodes[0];
    if (!episode) throw new Error("Fixture projection missing");
    const engine = new AttentionEngine();
    const base = {
      episode,
      events: [event],
      sourceId: "fixture-source",
      cueType: event.type,
      evaluationTime: "2026-08-12T10:05:00+08:00",
      timezoneOffsetMinutes: 480,
      quietHours: { startHour: 22, endHour: 7 },
      dailyBudget: { wakeLimit: 1, notifyLimit: 1, wakesUsed: 0, notificationsUsed: 0 },
      activeCooldownKeys: [] as string[],
    };
    const shadow = await engine.decide({ ...base, mode: "SHADOW" });
    expect(shadow.disposition).toBe("SHADOW_RECORDED");
    const wake = await engine.decide({ ...base, mode: "WAKE" });
    expect(wake.disposition).toBe("WAKE_QUEUED");
    const quiet = await engine.decide({
      ...base,
      mode: "WAKE",
      evaluationTime: "2026-08-12T23:05:00+08:00",
    });
    expect(quiet.decision.reasonCodes).toContain("QUIET_HOURS_ACTIVE");
    const exhausted = await engine.decide({
      ...base,
      mode: "WAKE",
      dailyBudget: { ...base.dailyBudget, wakesUsed: 1 },
    });
    expect(exhausted.decision.reasonCodes).toContain("DAILY_WAKE_BUDGET_EXHAUSTED");
    const cooled = await engine.decide({
      ...base,
      mode: "WAKE",
      activeCooldownKeys: [wake.decision.cooldownKey],
    });
    expect(cooled.decision.reasonCodes).toContain("SEMANTIC_COOLDOWN_ACTIVE");
  });

  it("fails closed when a judge times out or returns an invalid contract", async () => {
    const invalidJudge: StructuredJudge = {
      modelRef: "invalid-test-judge",
      judge: () => Promise.resolve({ verdict: "DO_ANYTHING" }),
    };
    const result = await runStructuredJudge(invalidJudge, {
      signalVersion: "wakeoncue.signal/conversation-v1",
      commitment: "我明天提交方案",
      deadline: "2026-08-13",
      hasTrustedEvidence: true,
    });
    expect(result.attempts).toBe(2);
    expect(result.fallback).toBe(true);
    expect(result.output).toMatchObject({ verdict: "IGNORE", reasonCodes: ["JUDGE_FAILED_SAFE"] });

    const timeoutJudge: StructuredJudge = {
      modelRef: "timeout-test-judge",
      judge: () => new Promise(() => undefined),
    };
    const timedOut = await runStructuredJudge(
      timeoutJudge,
      {
        signalVersion: "wakeoncue.signal/conversation-v1",
        commitment: "我明天提交方案",
        deadline: "2026-08-13",
        hasTrustedEvidence: true,
      },
      { timeoutMs: 5 },
    );
    expect(timedOut).toMatchObject({ attempts: 2, fallback: true });
  });

  it("emits a bounded read-only observation request when commitment context is incomplete", async () => {
    const event = eventFor({
      id: "missing-deadline",
      occurredAt: "2026-08-12T10:05:00+08:00",
      segments: [{ text: "我会提交发布方案。", isSubject: true }],
      expectedWake: false,
    });
    const episode = replayCueEvents([event]).episodes[0];
    if (!episode) throw new Error("Fixture projection missing");
    const evaluation = await new AttentionEngine().decide({
      episode,
      events: [event],
      sourceId: "fixture-source",
      cueType: event.type,
      mode: "SHADOW",
      evaluationTime: event.occurredAt,
      timezoneOffsetMinutes: 480,
      quietHours: { startHour: 22, endHour: 7 },
      dailyBudget: { wakeLimit: 3, notifyLimit: 5, wakesUsed: 0, notificationsUsed: 0 },
      activeCooldownKeys: [],
    });
    expect(evaluation.decision.decision).toBe("OBSERVE_MORE");
    expect(evaluation.observationRequest).toMatchObject({
      capability: "conversation.recent_segments",
      maxCost: 1,
      ttlSeconds: 120,
      retention: "PT5M",
    });
  });
});

describe("observation broker", () => {
  it("only authorizes registered read-only capabilities within scope, budget, and TTL", () => {
    const broker = new ObservationBroker();
    broker.register({
      name: "conversation.recent_segments",
      readOnly: true,
      allowedScopes: ["conversation:current:last-2m"],
      maxCost: 1,
      maxTtlSeconds: 120,
    });
    expect(
      broker.authorize({
        capability: "conversation.recent_segments",
        purpose: "resolve commitment referent",
        dataScope: ["conversation:current:last-2m"],
        maxCost: 1,
        ttlSeconds: 60,
        retention: "PT5M",
      }),
    ).toEqual({ authorized: true, expiresInSeconds: 60 });
    expect(() =>
      broker.authorize({
        capability: "tool.execute",
        purpose: "not observation",
        dataScope: [],
        maxCost: 0,
        ttlSeconds: 10,
        retention: "PT1M",
      }),
    ).toThrow("OBSERVATION_CAPABILITY_NOT_REGISTERED");
  });
});
