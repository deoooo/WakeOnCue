import cors from "@fastify/cors";
import Fastify, { type FastifyInstance } from "fastify";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

import { schemaRegistry } from "@wakeoncue/contracts";
import { deterministicId, sha256 } from "@wakeoncue/core";
import {
  GenericWebhookAdapter,
  verifyWebhookSignature,
  WebhookSignatureError,
} from "@wakeoncue/source-webhook";
import {
  IdempotencyConflictError,
  migrateDatabase,
  openDatabase,
  resolveDatabasePath,
  SqliteWakeStore,
} from "@wakeoncue/storage-sqlite";

function headerValue(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

function parseJson(rawBody: string): unknown {
  return JSON.parse(rawBody) as unknown;
}

export async function buildServer(): Promise<FastifyInstance> {
  const databasePath = resolveDatabasePath();
  mkdirSync(dirname(databasePath), { recursive: true });
  const database = openDatabase(databasePath);
  const appliedMigrations = migrateDatabase(database);
  const store = new SqliteWakeStore(database);
  const webhookAdapter = new GenericWebhookAdapter();
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

  server.addContentTypeParser("application/json", { parseAs: "string" }, (_request, body, done) => {
    done(null, body);
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

  server.post<{ Params: { sourceId: string }; Body: string }>(
    "/v1/sources/webhook/:sourceId",
    async (request, reply) => {
      const rawBody = request.body;
      const timestamp = headerValue(request.headers["x-wakeoncue-timestamp"]);
      const signature = headerValue(request.headers["x-wakeoncue-signature"]);
      const idempotencyKey = headerValue(request.headers["idempotency-key"]);
      const secret = process.env["WAKEONCUE_WEBHOOK_SECRET"];
      if (!secret) {
        return reply.code(503).send({ code: "SOURCE_SECRET_UNAVAILABLE", status: "error" });
      }

      try {
        verifyWebhookSignature({
          rawBody,
          timestamp,
          signature,
          secret,
          maxClockSkewSeconds: Number(process.env["WAKEONCUE_WEBHOOK_CLOCK_SKEW_SECONDS"] ?? "300"),
        });
      } catch (error) {
        const code = error instanceof WebhookSignatureError ? error.code : "SIGNATURE_INVALID";
        return reply.code(401).send({ code, status: "error" });
      }

      const receivedAt = new Date().toISOString();
      const bodyDigest = `sha256:${sha256(rawBody)}`;
      let parsed: unknown;
      try {
        parsed = parseJson(rawBody);
      } catch {
        store.recordIngressError({
          errorId: deterministicId(
            "ingress_error",
            `${request.params.sourceId}:${bodyDigest}:${timestamp ?? "missing"}`,
          ),
          sourceId: request.params.sourceId,
          bodyDigest,
          ...(idempotencyKey ? { idempotencyKey } : {}),
          reasonCode: "INVALID_JSON",
          details: ["Request body is not valid JSON"],
          createdAt: receivedAt,
        });
        return reply.code(400).send({ code: "INVALID_JSON", status: "quarantined" });
      }

      const validationErrors = webhookAdapter.validationErrors(parsed);
      if (!idempotencyKey || !webhookAdapter.validate(parsed)) {
        const details = [
          ...(idempotencyKey ? [] : ["/headers/idempotency-key: required"]),
          ...validationErrors,
        ];
        store.recordIngressError({
          errorId: deterministicId(
            "ingress_error",
            `${request.params.sourceId}:${bodyDigest}:${timestamp ?? "missing"}`,
          ),
          sourceId: request.params.sourceId,
          bodyDigest,
          ...(idempotencyKey ? { idempotencyKey } : {}),
          reasonCode: "SCHEMA_INVALID",
          details,
          createdAt: receivedAt,
        });
        return reply.code(400).send({ code: "SCHEMA_INVALID", details, status: "quarantined" });
      }

      const [event] = webhookAdapter.ingest(parsed, {
        sourceId: request.params.sourceId,
        receivedAt,
        idempotencyKey,
      });
      if (!event) return reply.code(400).send({ code: "NO_CUE_EVENT", status: "error" });
      try {
        const result = store.appendEvent(event);
        return reply.code(result.inserted ? 202 : 200).send({
          event: result.event,
          inserted: result.inserted,
          status: result.inserted ? "accepted" : "duplicate",
        });
      } catch (error) {
        if (error instanceof IdempotencyConflictError) {
          return reply.code(409).send({ code: "IDEMPOTENCY_CONFLICT", status: "error" });
        }
        throw error;
      }
    },
  );

  server.get<{ Params: { eventId: string } }>("/v1/events/:eventId", async (request, reply) => {
    const event = store.getEvent(request.params.eventId);
    return event
      ? reply.send({ event })
      : reply.code(404).send({ code: "EVENT_NOT_FOUND", status: "error" });
  });

  server.get<{ Params: { episodeId: string } }>(
    "/v1/episodes/:episodeId",
    async (request, reply) => {
      const episode = store.getEpisode(request.params.episodeId);
      return episode
        ? reply.send({ episode })
        : reply.code(404).send({ code: "EPISODE_NOT_FOUND", status: "error" });
    },
  );

  server.post<{ Body: string }>("/v1/replays", async (request, reply) => {
    if (!headerValue(request.headers["idempotency-key"])) {
      return reply.code(400).send({ code: "IDEMPOTENCY_KEY_REQUIRED", status: "error" });
    }
    let body: unknown;
    try {
      body = parseJson(request.body);
    } catch {
      return reply.code(400).send({ code: "INVALID_JSON", status: "error" });
    }
    const eventIds =
      typeof body === "object" &&
      body !== null &&
      Array.isArray((body as { eventIds?: unknown }).eventIds)
        ? (body as { eventIds: unknown[] }).eventIds
        : undefined;
    if (eventIds?.some((eventId) => typeof eventId !== "string")) {
      return reply.code(400).send({ code: "SCHEMA_INVALID", status: "error" });
    }
    const replay = store.replay(eventIds as string[] | undefined);
    return reply.send({ replay });
  });

  server.addHook("onClose", () => {
    database.close();
  });

  return server;
}
