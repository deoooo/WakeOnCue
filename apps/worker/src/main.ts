import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

import {
  migrateDatabase,
  openDatabase,
  resolveDatabasePath,
  SqliteWakeStore,
} from "@wakeoncue/storage-sqlite";

const databasePath = resolveDatabasePath();
mkdirSync(dirname(databasePath), { recursive: true });
const database = openDatabase(databasePath);
migrateDatabase(database);
const store = new SqliteWakeStore(database);

const poll = (): void => {
  try {
    const processed = store.processProjectionOutbox();
    if (processed > 0) {
      process.stdout.write(`${JSON.stringify({ processed, service: "wakeoncue-worker" })}\n`);
    }
  } catch (error) {
    process.stderr.write(
      `${JSON.stringify({ error: error instanceof Error ? error.message : "unknown", service: "wakeoncue-worker" })}\n`,
    );
  }
};

const interval = setInterval(poll, 1_000);
process.stdout.write(
  `${JSON.stringify({ databasePath, service: "wakeoncue-worker", status: "ready" })}\n`,
);

const shutdown = (signal: string): void => {
  clearInterval(interval);
  database.close();
  process.stdout.write(
    `${JSON.stringify({ service: "wakeoncue-worker", signal, status: "stopped" })}\n`,
  );
};

process.once("SIGINT", () => shutdown("SIGINT"));
process.once("SIGTERM", () => shutdown("SIGTERM"));
