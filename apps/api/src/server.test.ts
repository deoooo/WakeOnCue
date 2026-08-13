import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { signWebhook } from "@wakeoncue/source-webhook";
import { migrateDatabase, openDatabase } from "@wakeoncue/storage-sqlite";

import { buildServer } from "./server.ts";

describe("API bootstrap", () => {
  beforeEach(() => {
    process.env["WAKEONCUE_DATABASE_PATH"] = ":memory:";
    process.env["WAKEONCUE_WEBHOOK_SECRET"] = "test-only-webhook-secret";
    process.env["WAKEONCUE_LOG_LEVEL"] = "silent";
    process.env["WAKEONCUE_OMI_WEBHOOK_TOKEN"] = "test-only-omi-token";
    process.env["WAKEONCUE_OMI_SUBJECT"] = "omi-test-subject";
    process.env["WAKEONCUE_RUNTIME_CALLBACK_SECRET"] = "test-only-runtime-callback-secret";
    process.env["WAKEONCUE_RUNTIME_PEP_SECRET"] = "test-only-runtime-pep-secret";
    process.env["WAKEONCUE_APPROVAL_ADMIN_TOKEN"] = "test-only-approval-admin-token";
  });

  afterEach(() => {
    delete process.env["WAKEONCUE_DATABASE_PATH"];
    delete process.env["WAKEONCUE_WEBHOOK_SECRET"];
    delete process.env["WAKEONCUE_LOG_LEVEL"];
    delete process.env["WAKEONCUE_OMI_WEBHOOK_TOKEN"];
    delete process.env["WAKEONCUE_OMI_SUBJECT"];
    delete process.env["WAKEONCUE_RUNTIME_CALLBACK_SECRET"];
    delete process.env["WAKEONCUE_RUNTIME_PEP_SECRET"];
    delete process.env["WAKEONCUE_APPROVAL_ADMIN_TOKEN"];
  });

  it("reports health and migration readiness", async () => {
    const server = await buildServer();
    try {
      const health = await server.inject({ method: "GET", url: "/health" });
      expect(health.statusCode).toBe(200);
      expect(health.json()).toMatchObject({ status: "ok", service: "wakeoncue-api" });
      const ready = await server.inject({ method: "GET", url: "/ready" });
      expect(ready.statusCode).toBe(200);
      expect(ready.json()).toMatchObject({ status: "ready", database: "ready" });
      const schemas = await server.inject({ method: "GET", url: "/v1/schemas" });
      expect(schemas.statusCode).toBe(200);
      expect(schemas.json<{ versions: string[] }>().versions).toEqual(
        expect.arrayContaining([
          "wakeoncue.event/v1",
          "wakeoncue.decision/v1",
          "wakeoncue.task/v1",
          "wakeoncue.attempt/v1",
          "wakeoncue.permit/v1",
          "wakeoncue.outcome/v1",
          "wakeoncue.notification/v1",
        ]),
      );
    } finally {
      await server.close();
    }
  });

  it("authenticates, validates, stores, deduplicates, and replays a signed webhook", async () => {
    const server = await buildServer();
    const timestamp = Math.floor(Date.now() / 1000);
    const payload = JSON.stringify({
      specVersion: "wakeoncue.source.webhook/v1",
      providerEventId: "provider-api-1",
      type: "business.anomaly.detected",
      subject: "user-api",
      occurredAt: new Date(timestamp * 1000).toISOString(),
      correlationId: "anomaly-api-1",
      confidence: 0.98,
      data: { status: "open" },
      evidenceRefs: [
        {
          uri: "fixture://api/provider-api-1",
          mediaType: "application/json",
          classification: "private",
        },
      ],
      privacy: { purpose: ["attention"], retention: "P7D" },
    });
    const headers = {
      "content-type": "application/json",
      "idempotency-key": "api-request-1",
      "x-wakeoncue-timestamp": String(timestamp),
      "x-wakeoncue-signature": signWebhook(payload, timestamp, "test-only-webhook-secret"),
    };
    try {
      const accepted = await server.inject({
        method: "POST",
        url: "/v1/sources/webhook/source-api",
        headers,
        payload,
      });
      expect(accepted.statusCode).toBe(202);
      const acceptedBody = accepted.json<{ event: { eventId: string }; inserted: boolean }>();
      expect(acceptedBody.inserted).toBe(true);

      const duplicate = await server.inject({
        method: "POST",
        url: "/v1/sources/webhook/source-api",
        headers,
        payload,
      });
      expect(duplicate.statusCode).toBe(200);
      expect(duplicate.json()).toMatchObject({ inserted: false, status: "duplicate" });

      const stored = await server.inject({
        method: "GET",
        url: `/v1/events/${acceptedBody.event.eventId}`,
      });
      expect(stored.statusCode).toBe(200);
      expect(stored.json()).toMatchObject({ event: { source: { adapter: "webhook" } } });

      const replay = await server.inject({
        method: "POST",
        url: "/v1/replays",
        headers: { "content-type": "application/json", "idempotency-key": "replay-api-1" },
        payload: JSON.stringify({ eventIds: [acceptedBody.event.eventId] }),
      });
      expect(replay.statusCode).toBe(200);
      expect(replay.json()).toMatchObject({ replay: { eventCount: 1, duplicateCount: 0 } });

      const unauthorized = await server.inject({
        method: "POST",
        url: "/v1/sources/webhook/source-api",
        headers: { ...headers, "x-wakeoncue-signature": "v1=invalid" },
        payload,
      });
      expect(unauthorized.statusCode).toBe(401);

      const invalidPayload = JSON.stringify({ specVersion: "wakeoncue.source.webhook/v1" });
      const invalid = await server.inject({
        method: "POST",
        url: "/v1/sources/webhook/source-api",
        headers: {
          ...headers,
          "idempotency-key": "api-invalid-1",
          "x-wakeoncue-signature": signWebhook(
            invalidPayload,
            timestamp,
            "test-only-webhook-secret",
          ),
        },
        payload: invalidPayload,
      });
      expect(invalid.statusCode).toBe(400);
      expect(invalid.json()).toMatchObject({ status: "quarantined", code: "SCHEMA_INVALID" });
    } finally {
      await server.close();
    }
  });

  it("ingests an authenticated finalized Omi fixture in default Shadow mode", async () => {
    const server = await buildServer();
    const payload = readFileSync(
      resolve("packages/source-omi/fixtures/finalized-conversation.v1.json"),
      "utf8",
    );
    try {
      const unauthorized = await server.inject({
        method: "POST",
        url: "/v1/sources/omi/omi-local",
        headers: { authorization: "Bearer wrong", "content-type": "application/json" },
        payload,
      });
      expect(unauthorized.statusCode).toBe(401);

      const accepted = await server.inject({
        method: "POST",
        url: "/v1/sources/omi/omi-local",
        headers: {
          authorization: "Bearer test-only-omi-token",
          "content-type": "application/json",
        },
        payload,
      });
      expect(accepted.statusCode).toBe(202);
      expect(accepted.json()).toMatchObject({
        inserted: true,
        mode: "SHADOW",
        event: {
          type: "conversation.finalized",
          subject: "omi-test-subject",
          source: { adapter: "omi-finalized-conversation" },
        },
      });

      const rejectedMode = await server.inject({
        method: "PUT",
        url: "/v1/source-modes/omi-local/conversation.finalized",
        headers: { "content-type": "application/json" },
        payload: JSON.stringify({ mode: "NOTIFY" }),
      });
      expect(rejectedMode.statusCode).toBe(422);
      expect(rejectedMode.json()).toMatchObject({ code: "SOURCE_MODE_GATE_NOT_SATISFIED" });

      const forgedEvidence = await server.inject({
        method: "PUT",
        url: "/v1/source-modes/omi-local/conversation.finalized",
        headers: { "content-type": "application/json" },
        payload: JSON.stringify({
          mode: "WAKE",
          gateEvidence: {
            shadowDays: 99,
            explicitCommitmentPrecision: 1,
            falseWakeRatePerUserDay: 0,
          },
        }),
      });
      expect(forgedEvidence.statusCode).toBe(400);

      const shadow = await server.inject({
        method: "PUT",
        url: "/v1/source-modes/omi-local/conversation.finalized",
        headers: { "content-type": "application/json" },
        payload: JSON.stringify({ mode: "SHADOW" }),
      });
      expect(shadow.statusCode).toBe(200);
      expect(shadow.json()).toMatchObject({ sourceMode: { mode: "SHADOW" } });
    } finally {
      await server.close();
    }
  });

  it("authenticates and deduplicates an OpenClaw runtime callback before state transition", async () => {
    const directory = mkdtempSync(join(tmpdir(), "wakeoncue-api-runtime-"));
    const databasePath = join(directory, "runtime.sqlite");
    process.env["WAKEONCUE_DATABASE_PATH"] = databasePath;
    const database = openDatabase(databasePath);
    migrateDatabase(database);
    database
      .prepare(
        `INSERT INTO episodes(episode_id, subject, correlation_key, state_json, version, updated_at)
         VALUES ('ep_api_runtime', 'subject-api', 'runtime-api', '{}', 1, ?)`,
      )
      .run(new Date().toISOString());
    database
      .prepare(
        `INSERT INTO decisions(
          decision_id, episode_id, decision, reason_codes_json, evidence_refs_json,
          strategy_version, record_json, created_at
        ) VALUES ('dec_api_runtime', 'ep_api_runtime', 'WAKE_AGENT', '[]', '[]', 'test/v1', '{}', ?)`,
      )
      .run(new Date().toISOString());
    database
      .prepare(
        `INSERT INTO tasks(
          task_id, decision_id, idempotency_key, contract_json, status, created_at, updated_at
        ) VALUES ('task_api_runtime', 'dec_api_runtime', 'task-api-runtime', '{}', 'RUN_ACCEPTED', ?, ?)`,
      )
      .run(new Date().toISOString(), new Date().toISOString());
    database
      .prepare(
        `INSERT INTO runtime_runs(
          runtime_run_id, task_id, adapter, external_run_id, agent_run_id,
          idempotency_key, status, last_observed_at, record_json
        ) VALUES (
          'run_api_runtime', 'task_api_runtime', 'openclaw', 'activation-api-runtime', NULL,
          'run-api-runtime', 'RUN_ACCEPTED', ?, '{}'
        )`,
      )
      .run(new Date(Date.now() - 1_000).toISOString());
    database.close();

    const server = await buildServer();
    const timestamp = Math.floor(Date.now() / 1_000);
    const payload = JSON.stringify({
      specVersion: "wakeoncue.runtime.callback/v1",
      runtimeRunId: "run_api_runtime",
      taskId: "task_api_runtime",
      agentRunId: "agent-run-api-runtime",
      status: "RUNNING",
      occurredAt: new Date().toISOString(),
      evidenceRefs: [],
    });
    const headers = {
      "content-type": "application/json",
      "x-wakeoncue-timestamp": String(timestamp),
      "x-wakeoncue-signature": signWebhook(payload, timestamp, "test-only-runtime-callback-secret"),
    };
    try {
      const accepted = await server.inject({
        method: "POST",
        url: "/v1/runtime/callbacks/openclaw",
        headers,
        payload,
      });
      expect(accepted.statusCode).toBe(202);
      expect(accepted.json()).toMatchObject({
        inserted: true,
        runtimeRun: {
          agentRunId: "agent-run-api-runtime",
          externalRunId: "activation-api-runtime",
          status: "RUNNING",
        },
      });

      const duplicate = await server.inject({
        method: "POST",
        url: "/v1/runtime/callbacks/openclaw",
        headers,
        payload,
      });
      expect(duplicate.statusCode).toBe(200);
      expect(duplicate.json()).toMatchObject({ inserted: false, status: "duplicate" });

      const forged = await server.inject({
        method: "POST",
        url: "/v1/runtime/callbacks/openclaw",
        headers: { ...headers, "x-wakeoncue-signature": "v1=forged" },
        payload,
      });
      expect(forged.statusCode).toBe(401);
    } finally {
      await server.close();
    }
  });

  it("requires a signed PEP request and separate human approval before consuming one permit", async () => {
    const directory = mkdtempSync(join(tmpdir(), "wakeoncue-api-approval-"));
    const databasePath = join(directory, "approval.sqlite");
    process.env["WAKEONCUE_DATABASE_PATH"] = databasePath;
    const now = new Date().toISOString();
    const contract = {
      contractVersion: "wakeoncue.task/v1",
      taskId: "task_api_approval",
      subject: "subject-api-approval",
      goal: "Send the final quote",
      successCriteria: ["Exact recipient and attachment"],
      constraints: ["One-time approval required"],
      contextRefs: ["fixture://api/approval"],
      runtime: { adapter: "openclaw", profile: "default" },
      capabilityScope: ["evidence.read", "task.plan"],
      approvalRequiredFor: ["external.send"],
      idempotencyKey: "api-approval-task",
    };
    const database = openDatabase(databasePath);
    migrateDatabase(database);
    database
      .prepare(
        `INSERT INTO episodes(episode_id, subject, correlation_key, state_json, version, updated_at)
         VALUES ('ep_api_approval', ?, 'api-approval', '{}', 1, ?)`,
      )
      .run(contract.subject, now);
    database
      .prepare(
        `INSERT INTO decisions(
          decision_id, episode_id, decision, reason_codes_json, evidence_refs_json,
          strategy_version, record_json, created_at
        ) VALUES ('dec_api_approval', 'ep_api_approval', 'WAKE_AGENT', '[]', '[]', 'test/v1', '{}', ?)`,
      )
      .run(now);
    database
      .prepare(
        `INSERT INTO tasks(
          task_id, decision_id, idempotency_key, contract_json, status, created_at, updated_at
        ) VALUES (?, 'dec_api_approval', ?, ?, 'RUNNING', ?, ?)`,
      )
      .run(contract.taskId, contract.idempotencyKey, JSON.stringify(contract), now, now);
    database
      .prepare(
        `INSERT INTO runtime_runs(
          runtime_run_id, task_id, adapter, external_run_id, agent_run_id,
          idempotency_key, status, last_observed_at, record_json
        ) VALUES (
          'run_api_approval', ?, 'openclaw', 'activation-api-approval', 'agent-api-approval',
          'run-api-approval', 'RUNNING', ?, '{}'
        )`,
      )
      .run(contract.taskId, now);
    database.close();

    const server = await buildServer();
    const timestamp = Math.floor(Date.now() / 1_000);
    const attemptPayload = JSON.stringify({
      specVersion: "wakeoncue.runtime.tool-attempt/v1",
      taskId: contract.taskId,
      runtimeRunId: "run_api_approval",
      agentRunId: "agent-api-approval",
      toolCallId: "tool-call-api-send",
      tool: "file.send",
      arguments: { recipient: "contact:zhangsan", attachment: "final-quote.pdf" },
    });
    const pepHeaders = {
      "content-type": "application/json",
      "x-wakeoncue-timestamp": String(timestamp),
      "x-wakeoncue-signature": signWebhook(
        attemptPayload,
        timestamp,
        "test-only-runtime-pep-secret",
      ),
    };
    try {
      const forged = await server.inject({
        method: "POST",
        url: "/v1/runtime/tool-attempts/openclaw",
        headers: { ...pepHeaders, "x-wakeoncue-signature": "v1=forged" },
        payload: attemptPayload,
      });
      expect(forged.statusCode).toBe(401);

      const waiting = await server.inject({
        method: "POST",
        url: "/v1/runtime/tool-attempts/openclaw",
        headers: pepHeaders,
        payload: attemptPayload,
      });
      expect(waiting.statusCode).toBe(202);
      const attemptId = waiting.json<{
        authorization: { attempt: { attempt: { attemptId: string } }; decision: string };
      }>().authorization.attempt.attempt.attemptId;
      expect(waiting.json()).toMatchObject({
        authorization: { decision: "APPROVE_ONCE" },
        status: "waiting-approval",
      });

      const unauthorizedApproval = await server.inject({
        method: "POST",
        url: `/v1/approvals/${attemptId}`,
        headers: { "content-type": "application/json" },
        payload: JSON.stringify({ decision: "APPROVE_ONCE" }),
      });
      expect(unauthorizedApproval.statusCode).toBe(401);

      const approved = await server.inject({
        method: "POST",
        url: `/v1/approvals/${attemptId}`,
        headers: {
          authorization: "Bearer test-only-approval-admin-token",
          "content-type": "application/json",
        },
        payload: JSON.stringify({ decision: "APPROVE_ONCE" }),
      });
      expect(approved.statusCode).toBe(200);
      expect(approved.json()).toMatchObject({ attempt: { status: "APPROVED" } });

      const authorized = await server.inject({
        method: "POST",
        url: "/v1/runtime/tool-attempts/openclaw",
        headers: pepHeaders,
        payload: attemptPayload,
      });
      expect(authorized.statusCode).toBe(200);
      expect(authorized.json()).toMatchObject({
        authorization: { decision: "ALLOW", reasonCode: "VALID_ONE_TIME_PERMIT_CONSUMED" },
      });

      const replayed = await server.inject({
        method: "POST",
        url: "/v1/runtime/tool-attempts/openclaw",
        headers: pepHeaders,
        payload: attemptPayload,
      });
      expect(replayed.statusCode).toBe(200);
      expect(replayed.json()).toMatchObject({
        authorization: { decision: "DENY", reasonCode: "PERMIT_ALREADY_CONSUMED" },
      });

      const resultPayload = JSON.stringify({
        specVersion: "wakeoncue.runtime.tool-result/v1",
        attemptId,
        taskId: contract.taskId,
        runtimeRunId: "run_api_approval",
        agentRunId: "agent-api-approval",
        toolCallId: "tool-call-api-send",
        occurredAt: new Date().toISOString(),
        status: "SUCCEEDED",
        resultDigest: `sha256:${"b".repeat(64)}`,
      });
      const resultTimestamp = Math.floor(Date.now() / 1_000);
      const result = await server.inject({
        method: "POST",
        url: "/v1/runtime/tool-results/openclaw",
        headers: {
          "content-type": "application/json",
          "x-wakeoncue-timestamp": String(resultTimestamp),
          "x-wakeoncue-signature": signWebhook(
            resultPayload,
            resultTimestamp,
            "test-only-runtime-pep-secret",
          ),
        },
        payload: resultPayload,
      });
      expect(result.statusCode).toBe(200);
      expect(result.json()).toMatchObject({ attempt: { status: "SUCCEEDED" } });
    } finally {
      await server.close();
    }
  });
});
