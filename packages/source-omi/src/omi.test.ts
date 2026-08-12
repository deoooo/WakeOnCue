import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import { assertSourceConformance } from "@wakeoncue/source-sdk";

import { OmiFinalizedConversationAdapter } from "./index.js";

const packageDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const fixture = JSON.parse(
  readFileSync(resolve(packageDirectory, "fixtures/finalized-conversation.v1.json"), "utf8"),
) as unknown;

describe("Omi finalized conversation adapter", () => {
  it("maps the documented provider shape to a deterministic provider-neutral CueEvent", () => {
    const adapter = new OmiFinalizedConversationAdapter();
    const [event] = assertSourceConformance(
      adapter,
      fixture,
      { discarded: true },
      {
        sourceId: "omi-fixture",
        subject: "user-fixture",
        receivedAt: "2026-08-12T02:05:03.000Z",
      },
    );

    expect(event?.type).toBe("conversation.finalized");
    expect(event?.source.adapter).toBe("omi-finalized-conversation");
    expect(event?.data).not.toHaveProperty("transcript_segments");
    expect(event?.data).not.toHaveProperty("structured");
    expect(event?.evidenceRefs[0]?.uri).toContain("conversation_fixture_001");
  });

  it("rejects discarded conversations", () => {
    const adapter = new OmiFinalizedConversationAdapter();
    expect(adapter.validate({ ...(fixture as object), discarded: true })).toBe(false);
  });
});
