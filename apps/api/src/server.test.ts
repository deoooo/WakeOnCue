import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { signWebhook } from "@wakeoncue/source-webhook";

import { buildServer } from "./server.ts";

describe("API bootstrap", () => {
  beforeEach(() => {
    process.env["WAKEONCUE_DATABASE_PATH"] = ":memory:";
    process.env["WAKEONCUE_WEBHOOK_SECRET"] = "test-only-webhook-secret";
    process.env["WAKEONCUE_LOG_LEVEL"] = "silent";
    process.env["WAKEONCUE_OMI_WEBHOOK_TOKEN"] = "test-only-omi-token";
    process.env["WAKEONCUE_OMI_SUBJECT"] = "omi-test-subject";
  });

  afterEach(() => {
    delete process.env["WAKEONCUE_DATABASE_PATH"];
    delete process.env["WAKEONCUE_WEBHOOK_SECRET"];
    delete process.env["WAKEONCUE_LOG_LEVEL"];
    delete process.env["WAKEONCUE_OMI_WEBHOOK_TOKEN"];
    delete process.env["WAKEONCUE_OMI_SUBJECT"];
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
});
