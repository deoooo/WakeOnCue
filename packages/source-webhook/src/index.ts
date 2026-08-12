import { createHmac, timingSafeEqual } from "node:crypto";

import { Type, type Static } from "@sinclair/typebox";
import { Value } from "@sinclair/typebox/value";

import type { CueEvent } from "@wakeoncue/contracts";
import { deterministicId } from "@wakeoncue/core";
import type { SourceAdapter, SourceAdapterContext } from "@wakeoncue/source-sdk";

export const GenericWebhookEventSchema = Type.Object(
  {
    specVersion: Type.Literal("wakeoncue.source.webhook/v1"),
    providerEventId: Type.String({ minLength: 1, maxLength: 255 }),
    type: Type.String({ minLength: 1 }),
    subject: Type.String({ minLength: 1 }),
    occurredAt: Type.String({
      pattern: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?(?:Z|[+-]\\d{2}:\\d{2})$",
    }),
    correlationId: Type.String({ minLength: 1 }),
    confidence: Type.Number({ minimum: 0, maximum: 1 }),
    data: Type.Record(Type.String(), Type.Unknown()),
    evidenceRefs: Type.Array(
      Type.Object(
        {
          uri: Type.String({ minLength: 1 }),
          mediaType: Type.String({ minLength: 1 }),
          classification: Type.Union([
            Type.Literal("public"),
            Type.Literal("internal"),
            Type.Literal("private"),
            Type.Literal("confidential"),
          ]),
        },
        { additionalProperties: false },
      ),
    ),
    privacy: Type.Object(
      {
        purpose: Type.Array(Type.String({ minLength: 1 }), { minItems: 1 }),
        retention: Type.String({ pattern: "^P" }),
      },
      { additionalProperties: false },
    ),
  },
  { $id: "GenericWebhookEventV1", additionalProperties: false },
);

export type GenericWebhookEvent = Static<typeof GenericWebhookEventSchema>;

export class GenericWebhookAdapter implements SourceAdapter<GenericWebhookEvent> {
  readonly adapterId = "webhook";
  readonly contractVersion = "wakeoncue.source.webhook/v1";

  validate(raw: unknown): raw is GenericWebhookEvent {
    return Value.Check(GenericWebhookEventSchema, raw);
  }

  validationErrors(raw: unknown): string[] {
    return [...Value.Errors(GenericWebhookEventSchema, raw)].map(
      (error) => `${error.path || "/"}: ${error.message}`,
    );
  }

  ingest(raw: GenericWebhookEvent, context: SourceAdapterContext): CueEvent[] {
    const stableKey = `${context.sourceId}:${context.idempotencyKey ?? raw.providerEventId}:v1`;
    return [
      {
        specVersion: "wakeoncue.event/v1",
        eventId: deterministicId("evt", `webhook:${stableKey}`),
        type: raw.type,
        source: {
          adapter: this.adapterId,
          sourceId: context.sourceId,
          providerRef: raw.providerEventId,
        },
        subject: raw.subject,
        occurredAt: raw.occurredAt,
        receivedAt: context.receivedAt,
        correlationId: raw.correlationId,
        confidence: raw.confidence,
        data: raw.data,
        evidenceRefs: raw.evidenceRefs,
        privacy: raw.privacy,
        idempotencyKey: `webhook:${stableKey}`,
      },
    ];
  }
}

export type SignatureFailureCode =
  "SIGNATURE_MISSING" | "TIMESTAMP_INVALID" | "TIMESTAMP_EXPIRED" | "SIGNATURE_INVALID";

export class WebhookSignatureError extends Error {
  constructor(readonly code: SignatureFailureCode) {
    super(code);
    this.name = "WebhookSignatureError";
  }
}

export function signWebhook(rawBody: string, timestampSeconds: number, secret: string): string {
  return `v1=${createHmac("sha256", secret).update(`${timestampSeconds}.${rawBody}`).digest("hex")}`;
}

export function verifyWebhookSignature(input: {
  rawBody: string;
  timestamp: string | undefined;
  signature: string | undefined;
  secret: string;
  nowMs?: number;
  maxClockSkewSeconds?: number;
}): void {
  if (!input.timestamp || !input.signature) throw new WebhookSignatureError("SIGNATURE_MISSING");
  if (!/^\d{10}$/.test(input.timestamp)) throw new WebhookSignatureError("TIMESTAMP_INVALID");
  const timestampSeconds = Number(input.timestamp);
  const nowSeconds = Math.floor((input.nowMs ?? Date.now()) / 1000);
  if (Math.abs(nowSeconds - timestampSeconds) > (input.maxClockSkewSeconds ?? 300)) {
    throw new WebhookSignatureError("TIMESTAMP_EXPIRED");
  }
  const expected = signWebhook(input.rawBody, timestampSeconds, input.secret);
  const expectedBuffer = Buffer.from(expected);
  const receivedBuffer = Buffer.from(input.signature);
  if (
    expectedBuffer.length !== receivedBuffer.length ||
    !timingSafeEqual(expectedBuffer, receivedBuffer)
  ) {
    throw new WebhookSignatureError("SIGNATURE_INVALID");
  }
}
