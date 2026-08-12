import { TypeCompiler } from "@sinclair/typebox/compiler";
import { describe, expect, it } from "vitest";

import { CueEventSchema, schemaRegistry } from "./index.ts";

describe("public contract registry", () => {
  it("contains every MVP contract as a versioned schema", () => {
    expect(Object.keys(schemaRegistry).sort()).toEqual([
      "wakeoncue.attempt/v1",
      "wakeoncue.decision/v1",
      "wakeoncue.event/v1",
      "wakeoncue.notification/v1",
      "wakeoncue.outcome/v1",
      "wakeoncue.permit/v1",
      "wakeoncue.task/v1",
    ]);
  });

  it("rejects provider-specific fields outside the source envelope", () => {
    const check = TypeCompiler.Compile(CueEventSchema);
    expect(
      check.Check({
        specVersion: "wakeoncue.event/v1",
        eventId: "evt_contract",
        type: "conversation.transcript.finalized",
        source: { adapter: "omi", sourceId: "omi-local", providerRef: "conversation-1" },
        subject: "user-local",
        occurredAt: "2026-08-12T12:00:00.000Z",
        receivedAt: "2026-08-12T12:00:01.000Z",
        correlationId: "conversation-1",
        confidence: 1,
        data: { transcript: "我周五前把最终报价发给张三。" },
        evidenceRefs: [
          {
            uri: "omi://conversation/1#segment=1",
            mediaType: "text/plain",
            classification: "private",
          },
        ],
        privacy: { purpose: ["attention"], retention: "P7D" },
        idempotencyKey: "omi:conversation-1:segment-1:v1",
        omiInternalConversationObject: {},
      }),
    ).toBe(false);
  });
});
