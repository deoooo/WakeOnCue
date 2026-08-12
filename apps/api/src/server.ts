import cors from "@fastify/cors";
import Fastify, { type FastifyInstance } from "fastify";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

import { schemaRegistry } from "@wakeoncue/contracts";
import { migrateDatabase, openDatabase, resolveDatabasePath } from "@wakeoncue/storage-sqlite";

export async function buildServer(): Promise<FastifyInstance> {
  const databasePath = resolveDatabasePath();
  mkdirSync(dirname(databasePath), { recursive: true });
  const database = openDatabase(databasePath);
  const appliedMigrations = migrateDatabase(database);
  const server = Fastify({
    logger: {
      level: process.env["WAKEONCUE_LOG_LEVEL"] ?? "info",
      redact: [
        "req.headers.authorization",
        "req.headers.x-wakeoncue-signature",
        "req.headers.x-openclaw-token",
      ],
    },
    requestIdHeader: "x-request-id",
  });

  await server.register(cors, {
    origin: [process.env["WAKEONCUE_CONSOLE_URL"] ?? "http://127.0.0.1:4173"],
  });

  server.get("/health", () => ({
    service: "wakeoncue-api",
    status: "ok",
    version: "0.1.0",
  }));

  server.get("/ready", () => ({
    database: "ready",
    migrationsAppliedAtStartup: appliedMigrations,
    status: "ready",
  }));

  server.get("/v1/schemas", () => ({
    schemas: schemaRegistry,
    versions: Object.keys(schemaRegistry).sort(),
  }));

  server.addHook("onClose", () => {
    database.close();
  });

  return server;
}
