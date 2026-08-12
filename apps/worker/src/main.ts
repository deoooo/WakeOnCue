import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

import { migrateDatabase, openDatabase, resolveDatabasePath } from "@wakeoncue/storage-sqlite";

const databasePath = resolveDatabasePath();
mkdirSync(dirname(databasePath), { recursive: true });
const database = openDatabase(databasePath);
migrateDatabase(database);

const poll = (): void => {
  const pending = database
    .prepare("SELECT COUNT(*) AS count FROM outbox WHERE status = 'PENDING' AND available_at <= ?")
    .get(new Date().toISOString()) as { count: number };
  if (pending.count > 0) {
    process.stdout.write(
      `${JSON.stringify({ pending: pending.count, service: "wakeoncue-worker" })}\n`,
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
