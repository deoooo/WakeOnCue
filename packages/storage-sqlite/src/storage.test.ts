import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import type { CueEvent } from "@wakeoncue/contracts";
import { AttentionEngine } from "@wakeoncue/attention";
import { activationReceipt } from "@wakeoncue/runtime-sdk";

import {
  IdempotencyConflictError,
  migrateDatabase,
  openDatabase,
  SourceModeGateError,
  SqliteWakeStore,
} from "./index.ts";

const cueEvent = (overrides: Partial<CueEvent> = {}): CueEvent => ({
  specVersion: "wakeoncue.event/v1",
  eventId: "evt_storage",
  type: "conversation.commitment.detected",
  source: { adapter: "webhook", sourceId: "source-local", providerRef: "provider-1" },
  subject: "user-local",
  occurredAt: "2026-08-12T10:00:00.000Z",
  receivedAt: "2026-08-12T10:00:01.000Z",
  correlationId: "conversation-1",
  confidence: 0.95,
  data: { deadline: "2026-08-14" },
  evidenceRefs: [{ uri: "fixture://storage", mediaType: "text/plain", classification: "private" }],
  privacy: { purpose: ["attention"], retention: "P7D" },
  idempotencyKey: "fixture:storage:v1",
  ...overrides,
});

describe("SQLite migrations", () => {
  it("are idempotent and create the MVP tables", () => {
    const directory = mkdtempSync(join(tmpdir(), "wakeoncue-storage-"));
    const database = openDatabase(join(directory, "test.sqlite"));
    try {
      expect(migrateDatabase(database)).toEqual([
        "001_initial.sql",
        "002_replay_first.sql",
        "003_conversation_attention.sql",
        "004_agent_wake.sql",
        "005_runtime_agent_run_id.sql",
      ]);
      expect(migrateDatabase(database)).toEqual([]);
      const tables = database
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        .all()
        .map((row) => (row as { name: string }).name);
      expect(tables).toEqual(
        expect.arrayContaining([
          "events",
          "episodes",
          "decisions",
          "tasks",
          "runtime_runs",
          "runtime_callback_events",
          "tool_attempts",
          "permits",
          "outcomes",
          "notifications",
          "outbox",
          "deliveries",
          "ingress_errors",
        ]),
      );
    } finally {
      database.close();
    }
  });

  it("appends facts and outbox atomically, deduplicates, projects, and replays", () => {
    const database = openDatabase(":memory:");
    migrateDatabase(database);
    const store = new SqliteWakeStore(database);
    try {
      const first = cueEvent();
      expect(store.appendEvent(first).inserted).toBe(true);
      expect(store.appendEvent({ ...first, receivedAt: "2026-08-12T10:00:02.000Z" }).inserted).toBe(
        false,
      );
      expect(() => store.appendEvent({ ...first, data: { deadline: "changed" } })).toThrowError(
        IdempotencyConflictError,
      );
      expect(store.processProjectionOutbox()).toBe(1);
      const replay = store.replay();
      expect(replay.eventCount).toBe(1);
      expect(replay.episodes).toHaveLength(1);
      expect(store.getEpisode(replay.episodes[0]?.episodeId ?? "missing")?.eventIds).toEqual([
        first.eventId,
      ]);
      const ledger = database
        .prepare("SELECT COUNT(*) AS count FROM deliveries WHERE consumer = 'projector-v1'")
        .get() as { count: number };
      expect(ledger.count).toBe(1);
      expect(() =>
        database
          .prepare("UPDATE events SET event_type = 'tampered' WHERE event_id = ?")
          .run(first.eventId),
      ).toThrowError("events are append-only");
    } finally {
      database.close();
    }
  });

  it("projects conversation cues into explainable Shadow decisions and enforces mode gates", async () => {
    const database = openDatabase(":memory:");
    migrateDatabase(database);
    const store = new SqliteWakeStore(database);
    try {
      const event = cueEvent({
        type: "conversation.finalized",
        data: {
          conversation: {
            segments: [
              {
                text: "我周五之前把最终报价发给张三。",
                speakerRef: "subject",
                isSubject: true,
                startSeconds: 0,
                endSeconds: 3,
              },
            ],
            actionItems: [],
          },
        },
      });
      store.appendEvent(event);
      expect(store.processProjectionOutbox()).toBe(1);
      expect(await store.processAttentionOutbox(new AttentionEngine())).toBe(1);
      const item = store.listEpisodes()[0];
      expect(item?.latestDecision).toMatchObject({
        mode: "SHADOW",
        disposition: "SHADOW_RECORDED",
        decision: { decision: "WAKE_AGENT" },
      });
      const entities = database
        .prepare("SELECT entity_type FROM entities ORDER BY entity_type")
        .all()
        .map((row) => (row as { entity_type: string }).entity_type);
      expect(entities).toEqual(["commitment", "deadline", "recipient"]);
      expect(() => store.setSourceMode("source-local", event.type, "NOTIFY")).toThrowError(
        SourceModeGateError,
      );
      store.recordSourceGateEvidence(
        "source-local",
        event.type,
        {
          shadowDays: 7,
          explicitCommitmentPrecision: 0.95,
          falseWakeRatePerUserDay: 0.1,
          privacyViolationCount: 0,
          evidenceRef: "fixture://gate/verified-synthetic-evidence",
        },
        "2026-08-12T10:05:00.000Z",
      );
      expect(store.setSourceMode("source-local", event.type, "NOTIFY").mode).toBe("NOTIFY");
    } finally {
      database.close();
    }
  });

  it("creates an outcome-based Task Contract and applies append-only runtime callbacks", async () => {
    const database = openDatabase(":memory:");
    migrateDatabase(database);
    const store = new SqliteWakeStore(database);
    try {
      const event = cueEvent({
        type: "conversation.finalized",
        data: {
          conversation: {
            segments: [
              {
                text: "我周五之前把最终报价发给张三。",
                speakerRef: "subject",
                isSubject: true,
                startSeconds: 0,
                endSeconds: 3,
              },
            ],
            actionItems: [],
          },
        },
      });
      store.recordSourceGateEvidence(event.source.sourceId, event.type, {
        shadowDays: 7,
        explicitCommitmentPrecision: 0.95,
        falseWakeRatePerUserDay: 0.1,
        privacyViolationCount: 0,
        evidenceRef: "fixture://gate/runtime-conformance",
        userExplicitlyEnabled: true,
        runtimeIdempotencyPassed: true,
        pepConformancePassed: true,
        authorizationAttackSuitePassed: true,
        sourcePauseAvailable: true,
      });
      store.setSourceMode(event.source.sourceId, event.type, "WAKE");
      store.appendEvent(event);
      store.processProjectionOutbox();
      await store.processAttentionOutbox(new AttentionEngine());

      const claim = store.claimWakeActivation(
        "openclaw",
        "http://127.0.0.1:4310/v1/runtime/callbacks/openclaw",
      );
      expect(claim?.contract).toMatchObject({
        goal: "Follow through on this commitment: 我周五之前把最终报价发给张三。",
        capabilityScope: ["task.plan", "evidence.read"],
        runtime: { adapter: "openclaw", profile: "default" },
      });
      expect(JSON.stringify(claim?.contract)).not.toContain("toolSteps");
      if (!claim) throw new Error("Expected wake activation claim");
      const activated = store.completeWakeActivation(
        claim,
        activationReceipt({
          externalRunId: "openclaw-run-storage-1",
          status: "RUN_ACCEPTED",
          acceptedAt: "2026-08-12T10:00:02.000Z",
          providerReceipt: { ok: true, runId: "openclaw-run-storage-1" },
        }),
      );
      expect(activated.status).toBe("RUN_ACCEPTED");

      const running = {
        specVersion: "wakeoncue.runtime.callback/v1" as const,
        runtimeRunId: claim.runtimeRunId,
        taskId: claim.contract.taskId,
        agentRunId: "openclaw-agent-run-storage-1",
        status: "RUNNING" as const,
        occurredAt: "2026-08-12T10:00:03.000Z",
        evidenceRefs: [],
      };
      expect(store.applyRuntimeCallback(running).inserted).toBe(true);
      expect(store.applyRuntimeCallback(running).inserted).toBe(false);
      expect(
        store.applyRuntimeCallback({
          ...running,
          status: "SUCCEEDED",
          occurredAt: "2026-08-12T10:00:04.000Z",
          summary: "OpenClaw agent turn completed",
        }).runtimeRun.status,
      ).toBe("SUCCEEDED");
      expect(store.getTaskTimeline(claim.contract.taskId)?.callbacks).toHaveLength(2);
      expect(() =>
        database.prepare("UPDATE runtime_callback_events SET status = 'FAILED'").run(),
      ).toThrowError("runtime callback events are append-only");
    } finally {
      database.close();
    }
  });

  it("marks interrupted activation UNKNOWN without placing it back on the retry queue", async () => {
    const database = openDatabase(":memory:");
    migrateDatabase(database);
    const store = new SqliteWakeStore(database);
    try {
      const event = cueEvent({
        type: "conversation.finalized",
        data: {
          conversation: {
            segments: [
              {
                text: "我明天下午把会议纪要发给李四。",
                speakerRef: "subject",
                isSubject: true,
                startSeconds: 0,
                endSeconds: 3,
              },
            ],
            actionItems: [],
          },
        },
      });
      store.recordSourceGateEvidence(event.source.sourceId, event.type, {
        shadowDays: 7,
        explicitCommitmentPrecision: 0.95,
        falseWakeRatePerUserDay: 0.1,
        privacyViolationCount: 0,
        evidenceRef: "fixture://gate/runtime-conformance",
        userExplicitlyEnabled: true,
        runtimeIdempotencyPassed: true,
        pepConformancePassed: true,
        authorizationAttackSuitePassed: true,
        sourcePauseAvailable: true,
      });
      store.setSourceMode(event.source.sourceId, event.type, "WAKE");
      store.appendEvent(event);
      store.processProjectionOutbox();
      await store.processAttentionOutbox(new AttentionEngine());
      const claim = store.claimWakeActivation("openclaw", "http://127.0.0.1/callback");
      if (!claim) throw new Error("Expected wake activation claim");
      database
        .prepare("UPDATE outbox SET claimed_at = ? WHERE outbox_id = ?")
        .run("2026-08-12T09:00:00.000Z", claim.outboxId);
      expect(
        store.markStaleRuntimeActivationsUnknown(
          "2026-08-12T09:01:00.000Z",
          "2026-08-12T10:00:00.000Z",
        ),
      ).toBe(1);
      expect(store.getRuntimeRun(claim.runtimeRunId)?.status).toBe("UNKNOWN");
      expect(store.claimWakeActivation("openclaw", "http://127.0.0.1/callback")).toBeUndefined();
    } finally {
      database.close();
    }
  });
});
