import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import type { CueEvent, RuntimeToolAttemptRequest, TaskContract } from "@wakeoncue/contracts";
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
        "006_approval_permit.sql",
        "007_outcome_notification.sql",
        "008_retention_delete.sql",
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
          "native_notification_receipts",
          "notification_receipt_events",
          "outcome_events",
          "privacy_deletion_requests",
          "privacy_tombstones",
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

  it("tombstones retained payloads and removes subject projections without erasing audit identity", () => {
    const database = openDatabase(":memory:");
    migrateDatabase(database);
    const store = new SqliteWakeStore(database);
    const event = cueEvent({
      data: { transcript: "private phrase that must be removed", deadline: "2026-08-14" },
    });
    try {
      store.appendEvent(event);
      store.processProjectionOutbox();
      const episodeId = store.listEpisodes()[0]?.episode.episodeId;
      expect(episodeId).toBeTruthy();
      const deletion = store.deleteSubjectData(
        event.subject,
        "delete-private-fixture",
        "2026-08-13T09:00:00.000Z",
      );
      expect(deletion.counts).toEqual({ events: 1, episodes: 1, tasks: 0 });
      expect(store.getEvent(event.eventId)).toBeUndefined();
      expect(store.getEpisode(String(episodeId))).toBeUndefined();
      expect(store.listEpisodes()).toEqual([]);
      const raw = database
        .prepare(
          `SELECT e.event_id, e.idempotency_key, e.payload_hash, e.payload_json,
                  p.evidence_refs_json, p.tombstoned_at
           FROM events e JOIN event_payloads p ON p.event_id = e.event_id`,
        )
        .get() as Record<string, unknown>;
      expect(raw).toMatchObject({
        event_id: event.eventId,
        idempotency_key: event.idempotencyKey,
        evidence_refs_json: "[]",
        tombstoned_at: "2026-08-13T09:00:00.000Z",
      });
      expect(String(raw["payload_json"])).not.toContain("private phrase");
      expect(() => store.appendEvent(event)).toThrowError(IdempotencyConflictError);
    } finally {
      database.close();
    }
  });

  it("enforces exact one-time permits and rejects authorization attacks", () => {
    const database = openDatabase(":memory:");
    migrateDatabase(database);
    const store = new SqliteWakeStore(database);
    const now = "2026-08-13T10:00:00.000Z";
    const contract: TaskContract = {
      contractVersion: "wakeoncue.task/v1",
      taskId: "task_approval",
      subject: "subject-approval",
      goal: "Send the final quote to Zhang San",
      successCriteria: ["The exact approved file is sent to the exact approved recipient"],
      constraints: ["External writes require a one-time permit"],
      contextRefs: ["fixture://approval"],
      runtime: { adapter: "openclaw", profile: "default" },
      capabilityScope: ["evidence.read", "task.plan"],
      approvalRequiredFor: ["external.send", "calendar.write", "task.write"],
      idempotencyKey: "approval-fixture",
    };
    database
      .prepare(
        `INSERT INTO episodes(episode_id, subject, correlation_key, state_json, version, updated_at)
         VALUES ('ep_approval', ?, 'approval', '{}', 1, ?)`,
      )
      .run(contract.subject, now);
    database
      .prepare(
        `INSERT INTO decisions(
          decision_id, episode_id, decision, reason_codes_json, evidence_refs_json,
          strategy_version, record_json, created_at
        ) VALUES ('dec_approval', 'ep_approval', 'WAKE_AGENT', '[]', '[]', 'test/v1', '{}', ?)`,
      )
      .run(now);
    database
      .prepare(
        `INSERT INTO tasks(
          task_id, decision_id, idempotency_key, contract_json, status, created_at, updated_at
        ) VALUES (?, 'dec_approval', ?, ?, 'RUNNING', ?, ?)`,
      )
      .run(contract.taskId, contract.idempotencyKey, JSON.stringify(contract), now, now);
    database
      .prepare(
        `INSERT INTO runtime_runs(
          runtime_run_id, task_id, adapter, external_run_id, agent_run_id,
          idempotency_key, status, last_observed_at, record_json
        ) VALUES (
          'run_approval', ?, 'openclaw', 'activation-approval', 'agent-approval',
          'run-approval', 'RUNNING', ?, '{}'
        )`,
      )
      .run(contract.taskId, now);

    const sendRequest: RuntimeToolAttemptRequest = {
      specVersion: "wakeoncue.runtime.tool-attempt/v1",
      taskId: contract.taskId,
      runtimeRunId: "run_approval",
      agentRunId: "agent-approval",
      toolCallId: "tool-call-send-1",
      tool: "file.send",
      arguments: { recipient: "contact:zhangsan", attachment: "final-quote-v1.pdf" },
    };

    try {
      const waiting = store.submitRuntimeToolAttempt(sendRequest, now);
      expect(waiting).toMatchObject({
        decision: "APPROVE_ONCE",
        reasonCode: "EXTERNAL_WRITE_REQUIRES_APPROVAL",
        attempt: { status: "WAITING_APPROVAL" },
      });
      const approvalNotification = store
        .listNotifications(contract.taskId)
        .find((record) => record.notification.category === "approval");
      expect(approvalNotification).toBeTruthy();
      expect(
        database
          .prepare("SELECT available_at FROM outbox WHERE aggregate_id = ?")
          .get(approvalNotification?.notification.notificationId),
      ).toMatchObject({ available_at: now });
      expect(store.getRuntimeRun("run_approval")?.status).toBe("WAITING_APPROVAL");
      expect(
        store.applyRuntimeCallback({
          specVersion: "wakeoncue.runtime.callback/v1",
          runtimeRunId: "run_approval",
          taskId: contract.taskId,
          agentRunId: "agent-approval",
          status: "SUCCEEDED",
          occurredAt: "2026-08-13T10:00:01.500Z",
          summary: "Agent turn ended while a write remained paused",
          evidenceRefs: [],
        }).runtimeRun.status,
      ).toBe("WAITING_APPROVAL");
      expect(store.submitRuntimeToolAttempt(sendRequest, "2026-08-13T10:00:01.000Z").decision).toBe(
        "APPROVE_ONCE",
      );

      const approved = store.decideToolApproval(
        waiting.attempt.attempt.attemptId,
        "APPROVE_ONCE",
        "2026-08-13T10:00:02.000Z",
        60,
      );
      expect(approved.status).toBe("APPROVED");
      expect(approved.permit?.consumedAt).toBeUndefined();

      expect(() =>
        store.submitRuntimeToolAttempt(
          {
            ...sendRequest,
            priorAttemptId: waiting.attempt.attempt.attemptId,
            arguments: { recipient: "contact:lisi", attachment: "final-quote-v1.pdf" },
          },
          "2026-08-13T10:00:03.000Z",
        ),
      ).toThrowError("TOOL_ATTEMPT_BINDING_MISMATCH");
      expect(() =>
        store.submitRuntimeToolAttempt(
          {
            ...sendRequest,
            priorAttemptId: waiting.attempt.attempt.attemptId,
            arguments: { recipient: "contact:zhangsan", attachment: "final-quote-v2.pdf" },
          },
          "2026-08-13T10:00:03.000Z",
        ),
      ).toThrowError("TOOL_ATTEMPT_BINDING_MISMATCH");

      const authorized = store.submitRuntimeToolAttempt(
        { ...sendRequest, priorAttemptId: waiting.attempt.attempt.attemptId },
        "2026-08-13T10:00:03.000Z",
      );
      expect(authorized).toMatchObject({
        decision: "ALLOW",
        reasonCode: "VALID_ONE_TIME_PERMIT_CONSUMED",
        attempt: { status: "EXECUTING", permit: { consumedAt: "2026-08-13T10:00:03.000Z" } },
      });
      expect(store.getRuntimeRun("run_approval")?.status).toBe("RUNNING");
      expect(
        store.submitRuntimeToolAttempt(
          { ...sendRequest, priorAttemptId: waiting.attempt.attempt.attemptId },
          "2026-08-13T10:00:04.000Z",
        ),
      ).toMatchObject({ decision: "DENY", reasonCode: "PERMIT_ALREADY_CONSUMED" });

      const result = store.recordRuntimeToolResult({
        specVersion: "wakeoncue.runtime.tool-result/v1",
        attemptId: waiting.attempt.attempt.attemptId,
        taskId: contract.taskId,
        runtimeRunId: "run_approval",
        agentRunId: "agent-approval",
        toolCallId: sendRequest.toolCallId,
        occurredAt: "2026-08-13T10:00:05.000Z",
        status: "SUCCEEDED",
        resultDigest: `sha256:${"a".repeat(64)}`,
      });
      expect(result.status).toBe("SUCCEEDED");
      expect(store.listOutcomes(contract.taskId)).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ verification: "reported", status: "SUCCEEDED" }),
          expect.objectContaining({ verification: "tool-confirmed", status: "SUCCEEDED" }),
        ]),
      );
      const verified = store.recordExternalOutcomeVerification({
        specVersion: "wakeoncue.outcome.external-verification/v1",
        taskId: contract.taskId,
        runtimeRunId: "run_approval",
        status: "SUCCEEDED",
        summary: "Recipient system confirmed the exact delivery.",
        evidenceRefs: ["receipt-42"],
        occurredAt: "2026-08-13T10:00:06.000Z",
        verifier: "controlled-recipient-sink",
      });
      expect(verified.verification).toBe("externally-verified");
      expect(verified.specVersion).toBe("wakeoncue.outcome/v1");
      expect(verified).not.toHaveProperty("verifier");
      expect(verified.evidenceRefs).toEqual(["controlled-recipient-sink:receipt-42"]);
      const verifiedNotification = store
        .listNotifications(contract.taskId)
        .find((record) => record.notification.outcomeId === verified.outcomeId);
      expect(verifiedNotification?.notification.category).toBe("verified-completion");
      expect(
        database
          .prepare("SELECT available_at > ? AS delayed FROM outbox WHERE aggregate_id = ?")
          .get(verified.occurredAt, verifiedNotification?.notification.notificationId),
      ).toMatchObject({ delayed: 1 });
      const failed = store.recordExternalOutcomeVerification({
        specVersion: "wakeoncue.outcome.external-verification/v1",
        taskId: contract.taskId,
        runtimeRunId: "run_approval",
        status: "UNKNOWN",
        summary: "Receiver status could not be reconciled.",
        evidenceRefs: ["receipt-unknown"],
        occurredAt: "2026-08-13T15:00:00.000Z",
        verifier: "controlled-recipient-sink",
      });
      const failureNotification = store
        .listNotifications(contract.taskId)
        .find((record) => record.notification.outcomeId === failed.outcomeId);
      expect(failureNotification?.notification.category).toBe("high-risk-failure");
      expect(
        database
          .prepare("SELECT available_at FROM outbox WHERE aggregate_id = ?")
          .get(failureNotification?.notification.notificationId),
      ).toMatchObject({ available_at: failed.occurredAt });
      const quietSuccess = store.recordExternalOutcomeVerification({
        specVersion: "wakeoncue.outcome.external-verification/v1",
        taskId: contract.taskId,
        runtimeRunId: "run_approval",
        status: "SUCCEEDED",
        summary: "Late receiver confirmation.",
        evidenceRefs: ["receipt-late"],
        occurredAt: "2026-08-13T15:05:00.000Z",
        verifier: "controlled-recipient-sink",
      });
      const quietNotification = store
        .listNotifications(contract.taskId)
        .find((record) => record.notification.outcomeId === quietSuccess.outcomeId);
      expect(
        database
          .prepare("SELECT available_at FROM outbox WHERE aggregate_id = ?")
          .get(quietNotification?.notification.notificationId),
      ).toMatchObject({ available_at: "2026-08-13T23:00:00.000Z" });
      store.recordNativeNotificationReceipt({
        specVersion: "wakeoncue.notification.native-receipt/v1",
        receiptId: "native-receipt-42",
        taskId: contract.taskId,
        outcomeId: verified.outcomeId,
        runtimeRunId: "run_approval",
        channel: "openclaw-native",
        status: "DELIVERED",
        occurredAt: "2026-08-13T10:00:07.000Z",
      });
      expect(
        database
          .prepare("SELECT status FROM outbox WHERE aggregate_id = ?")
          .get(verifiedNotification?.notification.notificationId),
      ).toMatchObject({ status: "COMPLETED" });
      expect(
        store.getNotification(String(verifiedNotification?.notification.notificationId))?.status,
      ).toBe("NATIVE_DELIVERED");
      const feedback = {
        specVersion: "wakeoncue.feedback/v1" as const,
        taskId: contract.taskId,
        kind: "ACCEPTED" as const,
        occurredAt: "2026-08-13T10:00:08.000Z",
      };
      expect(store.recordTaskFeedback(feedback, "feedback-42")).toEqual(feedback);
      expect(store.recordTaskFeedback(feedback, "feedback-42")).toEqual(feedback);
      expect(() =>
        store.recordTaskFeedback({ ...feedback, kind: "REJECTED" }, "feedback-42"),
      ).toThrowError(IdempotencyConflictError);
      expect(
        (
          database
            .prepare("SELECT COUNT(*) AS count FROM deliveries WHERE consumer = 'tool-pep'")
            .get() as { count: number }
        ).count,
      ).toBe(1);

      const expiring = store.submitRuntimeToolAttempt(
        { ...sendRequest, toolCallId: "tool-call-send-expiring" },
        "2026-08-13T10:01:00.000Z",
      );
      store.decideToolApproval(
        expiring.attempt.attempt.attemptId,
        "APPROVE_ONCE",
        "2026-08-13T10:01:00.000Z",
        1,
      );
      expect(
        store.submitRuntimeToolAttempt(
          {
            ...sendRequest,
            toolCallId: "tool-call-send-expiring",
            priorAttemptId: expiring.attempt.attempt.attemptId,
          },
          "2026-08-13T10:01:02.000Z",
        ),
      ).toMatchObject({ decision: "DENY", reasonCode: "PERMIT_EXPIRED" });

      expect(
        store.submitRuntimeToolAttempt(
          { ...sendRequest, toolCallId: "tool-call-delete", tool: "calendar.delete" },
          "2026-08-13T10:02:00.000Z",
        ),
      ).toMatchObject({ decision: "DENY", reasonCode: "MVP_FORBIDDEN_OPERATION" });
      expect(
        store.submitRuntimeToolAttempt(
          {
            ...sendRequest,
            toolCallId: "tool-call-read",
            tool: "read",
            arguments: { path: "fixture://approval" },
          },
          "2026-08-13T10:02:01.000Z",
        ),
      ).toMatchObject({ decision: "ALLOW", reasonCode: "BOUNDED_READ_ALLOWED" });
      expect(() =>
        store.submitRuntimeToolAttempt(
          { ...sendRequest, toolCallId: "tool-call-forged", agentRunId: "forged-agent" },
          "2026-08-13T10:02:02.000Z",
        ),
      ).toThrowError("RUNTIME_AGENT_RUN_ID_MISMATCH");
      expect(() =>
        database.prepare("UPDATE permit_events SET event_type = 'TAMPERED'").run(),
      ).toThrowError("permit events are append-only");
      expect(() => database.prepare("DELETE FROM tool_attempt_events").run()).toThrowError(
        "tool attempt events are append-only",
      );

      const deletion = store.deleteSubjectData(
        contract.subject,
        "delete-subject-approval",
        "2026-08-13T10:03:00.000Z",
      );
      expect(deletion.counts).toMatchObject({ episodes: 1, tasks: 1 });
      expect(store.deleteSubjectData(contract.subject, "delete-subject-approval")).toEqual(
        deletion,
      );
      expect(store.getTask(contract.taskId)).toBeUndefined();
      expect(store.getRuntimeRun("run_approval")).toBeUndefined();
      expect(store.getToolAttempt(waiting.attempt.attempt.attemptId)).toBeUndefined();
      expect(store.listOutcomes(contract.taskId)).toEqual([]);
      expect(store.listNotifications(contract.taskId)).toEqual([]);
      expect(
        database.prepare("SELECT COUNT(*) count FROM privacy_deletion_context").get(),
      ).toMatchObject({ count: 0 });
      expect(
        database
          .prepare("SELECT COUNT(*) count FROM permits WHERE task_id = ? AND consumed_at IS NULL")
          .get(contract.taskId),
      ).toMatchObject({ count: 0 });
      expect(() =>
        database.prepare("UPDATE outcomes SET verification = 'forged'").run(),
      ).toThrowError("outcomes are append-only");
    } finally {
      database.close();
    }
  });
});
