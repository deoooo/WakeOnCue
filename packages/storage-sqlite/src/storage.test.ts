import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

import { migrateDatabase, openDatabase } from "./index.ts";

describe("SQLite migrations", () => {
  it("are idempotent and create the MVP tables", () => {
    const directory = mkdtempSync(join(tmpdir(), "wakeoncue-storage-"));
    const database = openDatabase(join(directory, "test.sqlite"));
    try {
      expect(migrateDatabase(database)).toEqual(["001_initial.sql"]);
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
        ]),
      );
    } finally {
      database.close();
    }
  });
});
