import { describe, expect, it } from "vitest";

import type { CueEvent } from "@wakeoncue/contracts";

import { replayCueEvents } from "./index.ts";

const event = (eventId: string, occurredAt: string, data: Record<string, unknown>): CueEvent => ({
  specVersion: "wakeoncue.event/v1",
  eventId,
  type: "conversation.commitment.detected",
  source: { adapter: "webhook", sourceId: "source-local", providerRef: eventId },
  subject: "user-local",
  occurredAt,
  receivedAt: occurredAt,
  correlationId: "conversation-1",
  confidence: 0.95,
  data,
  evidenceRefs: [
    { uri: `fixture://${eventId}`, mediaType: "text/plain", classification: "private" },
  ],
  privacy: { purpose: ["attention"], retention: "P7D" },
  idempotencyKey: `fixture:${eventId}`,
});

describe("deterministic replay", () => {
  it("deduplicates and produces the same projection regardless of input order", () => {
    const first = event("evt_first", "2026-08-12T10:00:00.000Z", { deadline: "2026-08-14" });
    const changed = event("evt_changed", "2026-08-12T10:01:00.000Z", {
      deadline: "2026-08-15",
    });
    const forward = replayCueEvents([first, changed, first]);
    const reverse = replayCueEvents([first, changed].reverse());

    expect(forward.eventCount).toBe(2);
    expect(forward.duplicateCount).toBe(1);
    expect(forward.episodes[0]?.deadlineHistory).toEqual(["2026-08-14", "2026-08-15"]);
    expect(forward.digest).toBe(reverse.digest);
    expect(forward.episodes).toEqual(reverse.episodes);
  });
});
