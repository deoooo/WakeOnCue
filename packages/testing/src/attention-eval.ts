import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { AttentionEngine } from "@wakeoncue/attention";
import type { CueEvent } from "@wakeoncue/contracts";
import { deterministicId, replayCueEvents } from "@wakeoncue/core";

interface CorpusCase {
  id: string;
  occurredAt: string;
  segments: Array<{ text: string; isSubject: boolean }>;
  expectedWake: boolean;
}

const corpus = JSON.parse(
  readFileSync(resolve("packages/testing/fixtures/conversation-attention-corpus.v1.json"), "utf8"),
) as { specVersion: string; cases: CorpusCase[] };

function eventFor(testCase: CorpusCase): CueEvent {
  return {
    specVersion: "wakeoncue.event/v1",
    eventId: deterministicId("evt", `attention-eval:${testCase.id}`),
    type: "conversation.finalized",
    source: { adapter: "fixture", sourceId: "attention-eval", providerRef: testCase.id },
    subject: "evaluation-user",
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
    idempotencyKey: `attention-eval:${testCase.id}`,
  };
}

const engine = new AttentionEngine();
const cases = [];
let truePositive = 0;
let falsePositive = 0;
let trueNegative = 0;
let falseNegative = 0;

for (const testCase of corpus.cases) {
  const event = eventFor(testCase);
  const episode = replayCueEvents([event]).episodes[0];
  if (!episode) throw new Error(`Missing projection for ${testCase.id}`);
  const evaluation = await engine.decide({
    episode,
    events: [event],
    sourceId: "attention-eval",
    cueType: event.type,
    mode: "SHADOW",
    evaluationTime: testCase.occurredAt,
    timezoneOffsetMinutes: 480,
    quietHours: { startHour: 22, endHour: 7 },
    dailyBudget: { wakeLimit: 3, notifyLimit: 5, wakesUsed: 0, notificationsUsed: 0 },
    activeCooldownKeys: [],
  });
  const actualWake = evaluation.decision.decision === "WAKE_AGENT";
  if (actualWake && testCase.expectedWake) truePositive += 1;
  else if (actualWake) falsePositive += 1;
  else if (testCase.expectedWake) falseNegative += 1;
  else trueNegative += 1;
  cases.push({
    id: testCase.id,
    expectedWake: testCase.expectedWake,
    actualDecision: evaluation.decision.decision,
    reasonCodes: evaluation.decision.reasonCodes,
  });
}

const precision = truePositive / (truePositive + falsePositive);
const recall = truePositive / (truePositive + falseNegative);
const passed = precision >= 0.9 && recall >= 0.75;
process.stdout.write(
  `${JSON.stringify(
    {
      corpus: corpus.specVersion,
      totals: {
        cases: corpus.cases.length,
        truePositive,
        falsePositive,
        trueNegative,
        falseNegative,
      },
      metrics: { precision, recall },
      gates: { precision: 0.9, recall: 0.75 },
      cases,
      status: passed ? "PASS" : "FAIL",
    },
    null,
    2,
  )}\n`,
);
if (!passed) process.exitCode = 1;
