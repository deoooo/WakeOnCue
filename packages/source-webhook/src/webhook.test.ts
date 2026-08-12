import { describe, expect, it } from "vitest";

import { assertSourceConformance } from "@wakeoncue/source-sdk";

import {
  GenericWebhookAdapter,
  signWebhook,
  verifyWebhookSignature,
  WebhookSignatureError,
} from "./index.ts";

const fixture = {
  specVersion: "wakeoncue.source.webhook/v1",
  providerEventId: "provider-1",
  type: "business.anomaly.detected",
  subject: "user-local",
  occurredAt: "2026-08-12T12:00:00.000Z",
  correlationId: "anomaly-1",
  confidence: 0.99,
  data: { status: "open" },
  evidenceRefs: [
    {
      uri: "fixture://webhook/provider-1",
      mediaType: "application/json",
      classification: "private",
    },
  ],
  privacy: { purpose: ["attention"], retention: "P7D" },
} as const;

describe("generic webhook source", () => {
  it("passes Source SDK conformance", () => {
    const events = assertSourceConformance(
      new GenericWebhookAdapter(),
      fixture,
      { ...fixture, providerEventId: "" },
      { sourceId: "source-local", receivedAt: "2026-08-12T12:00:01.000Z" },
    );
    expect(events[0]?.idempotencyKey).toBe("webhook:source-local:provider-1:v1");
  });

  it("accepts an exact HMAC and rejects expired or changed payloads", () => {
    const secret = "test-only-secret";
    const body = JSON.stringify(fixture);
    const timestamp = 1_786_536_000;
    const signature = signWebhook(body, timestamp, secret);
    expect(() =>
      verifyWebhookSignature({
        rawBody: body,
        timestamp: String(timestamp),
        signature,
        secret,
        nowMs: timestamp * 1000,
      }),
    ).not.toThrow();
    expect(() =>
      verifyWebhookSignature({
        rawBody: `${body} `,
        timestamp: String(timestamp),
        signature,
        secret,
        nowMs: timestamp * 1000,
      }),
    ).toThrowError(WebhookSignatureError);
    expect(() =>
      verifyWebhookSignature({
        rawBody: body,
        timestamp: String(timestamp),
        signature,
        secret,
        nowMs: (timestamp + 301) * 1000,
      }),
    ).toThrowError("TIMESTAMP_EXPIRED");
  });
});
