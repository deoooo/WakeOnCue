import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import type { CueEvent } from "@wakeoncue/contracts";

import {
  IdempotencyConflictError,
  migrateDatabase,
  openDatabase,
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
      expect(migrateDatabase(database)).toEqual(["001_initial.sql", "002_replay_first.sql"]);
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
});
