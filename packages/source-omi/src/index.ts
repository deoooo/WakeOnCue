import { Type, type Static } from "@sinclair/typebox";
import { Value } from "@sinclair/typebox/value";

import type { CueEvent } from "@wakeoncue/contracts";
import { deterministicId } from "@wakeoncue/core";
import type { SourceAdapter, SourceAdapterContext } from "@wakeoncue/source-sdk";

const Rfc3339 = Type.String({
  pattern: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?(?:Z|[+-]\\d{2}:\\d{2})$",
});

const OmiTranscriptSegmentSchema = Type.Object(
  {
    id: Type.Optional(Type.String({ minLength: 1 })),
    text: Type.String({ minLength: 1, maxLength: 2_000 }),
    speaker: Type.Optional(Type.String({ minLength: 1 })),
    speakerId: Type.Optional(Type.Number()),
    speaker_id: Type.Optional(Type.Number()),
    speaker_name: Type.Optional(Type.String({ minLength: 1 })),
    is_user: Type.Optional(Type.Boolean()),
    start: Type.Number({ minimum: 0 }),
    end: Type.Number({ minimum: 0 }),
  },
  { additionalProperties: true },
);

const OmiActionItemSchema = Type.Object(
  {
    description: Type.String({ minLength: 1 }),
    completed: Type.Boolean(),
    due_at: Type.Optional(Rfc3339),
  },
  { additionalProperties: true },
);

export const OmiFinalizedConversationSchema = Type.Object(
  {
    id: Type.String({ minLength: 1, maxLength: 255 }),
    created_at: Rfc3339,
    started_at: Rfc3339,
    finished_at: Rfc3339,
    source: Type.Optional(Type.String({ minLength: 1 })),
    language: Type.Optional(Type.String({ minLength: 1 })),
    status: Type.Optional(Type.Literal("completed")),
    discarded: Type.Boolean(),
    transcript_segments: Type.Array(OmiTranscriptSegmentSchema, { minItems: 1, maxItems: 500 }),
    structured: Type.Optional(
      Type.Object(
        {
          title: Type.Optional(Type.String()),
          overview: Type.Optional(Type.String()),
          action_items: Type.Optional(Type.Array(OmiActionItemSchema)),
        },
        { additionalProperties: true },
      ),
    ),
  },
  { $id: "OmiFinalizedConversationV1", additionalProperties: true },
);

export type OmiFinalizedConversation = Static<typeof OmiFinalizedConversationSchema>;

export class OmiFinalizedConversationAdapter implements SourceAdapter<OmiFinalizedConversation> {
  readonly adapterId = "omi-finalized-conversation";
  readonly contractVersion = "wakeoncue.source.omi-finalized/v1";

  validate(raw: unknown): raw is OmiFinalizedConversation {
    return Value.Check(OmiFinalizedConversationSchema, raw) && raw.discarded === false;
  }

  validationErrors(raw: unknown): string[] {
    const errors = [...Value.Errors(OmiFinalizedConversationSchema, raw)].map(
      (error) => `${error.path || "/"}: ${error.message}`,
    );
    if (typeof raw === "object" && raw !== null && "discarded" in raw && raw.discarded !== false) {
      errors.push("/discarded: finalized conversation must not be discarded");
    }
    return errors;
  }

  ingest(raw: OmiFinalizedConversation, context: SourceAdapterContext): CueEvent[] {
    if (!context.subject) throw new Error("Omi source requires a configured WakeOnCue subject");
    const stableKey = `${context.sourceId}:${raw.id}:finalized:v1`;
    return [
      {
        specVersion: "wakeoncue.event/v1",
        eventId: deterministicId("evt", `omi:${stableKey}`),
        type: "conversation.finalized",
        source: {
          adapter: this.adapterId,
          sourceId: context.sourceId,
          providerRef: raw.id,
        },
        subject: context.subject,
        occurredAt: raw.finished_at,
        receivedAt: context.receivedAt,
        correlationId: `conversation:${raw.id}`,
        confidence: 0.95,
        data: {
          conversation: {
            title: raw.structured?.title,
            overview: raw.structured?.overview,
            language: raw.language,
            segments: raw.transcript_segments.map((segment) => ({
              text: segment.text,
              speakerRef:
                segment.speaker ??
                segment.speaker_name ??
                String(segment.speakerId ?? segment.speaker_id ?? "unknown"),
              isSubject: segment.is_user ?? false,
              startSeconds: segment.start,
              endSeconds: segment.end,
            })),
            actionItems: (raw.structured?.action_items ?? []).map((item) => ({
              description: item.description,
              completed: item.completed,
              dueAt: item.due_at,
            })),
          },
        },
        evidenceRefs: [
          {
            uri: `omi://conversation/${encodeURIComponent(raw.id)}/transcript`,
            mediaType: "application/vnd.omi.conversation+json",
            classification: "private",
          },
        ],
        privacy: {
          purpose: ["attention", "task-activation"],
          retention: "P7D",
        },
        idempotencyKey: `omi:${stableKey}`,
      },
    ];
  }
}
