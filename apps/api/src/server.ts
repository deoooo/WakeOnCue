import cors from "@fastify/cors";
import Fastify, { type FastifyInstance } from "fastify";
import { Value } from "@sinclair/typebox/value";
import { timingSafeEqual } from "node:crypto";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

import {
  RuntimeCallbackSchema,
  RuntimeToolAttemptRequestSchema,
  RuntimeToolResultSchema,
  schemaRegistry,
} from "@wakeoncue/contracts";
import { deterministicId, sha256 } from "@wakeoncue/core";
import { OmiFinalizedConversationAdapter } from "@wakeoncue/source-omi";
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
  SourceModeGateError,
  SqliteWakeStore,
} from "@wakeoncue/storage-sqlite";

function headerValue(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

function parseJson(rawBody: string): unknown {
  return JSON.parse(rawBody) as unknown;
}

function bearerMatches(authorization: string | undefined, expected: string): boolean {
  const received = authorization?.startsWith("Bearer ") ? authorization.slice(7) : "";
  const receivedDigest = Buffer.from(sha256(received), "hex");
  const expectedDigest = Buffer.from(sha256(expected), "hex");
  return timingSafeEqual(receivedDigest, expectedDigest);
}

function isLoopbackAddress(address: string): boolean {
  return address === "127.0.0.1" || address === "::1" || address === "::ffff:127.0.0.1";
}

export async function buildServer(): Promise<FastifyInstance> {
  const databasePath = resolveDatabasePath();
  mkdirSync(dirname(databasePath), { recursive: true });
  const database = openDatabase(databasePath);
  const appliedMigrations = migrateDatabase(database);
  const store = new SqliteWakeStore(database);
  const webhookAdapter = new GenericWebhookAdapter();
  const omiAdapter = new OmiFinalizedConversationAdapter();
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
    methods: ["GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS"],
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

  server.post<{ Params: { sourceId: string }; Body: string }>(
    "/v1/sources/omi/:sourceId",
    async (request, reply) => {
      const token = process.env["WAKEONCUE_OMI_WEBHOOK_TOKEN"];
      const subject = process.env["WAKEONCUE_OMI_SUBJECT"];
      if (!token || !subject) {
        return reply.code(503).send({ code: "OMI_SOURCE_NOT_CONFIGURED", status: "error" });
      }
      if (!bearerMatches(headerValue(request.headers.authorization), token)) {
        return reply.code(401).send({ code: "SOURCE_AUTH_INVALID", status: "error" });
      }

      const receivedAt = new Date().toISOString();
      const bodyDigest = `sha256:${sha256(request.body)}`;
      let parsed: unknown;
      try {
        parsed = parseJson(request.body);
      } catch {
        store.recordIngressError({
          errorId: deterministicId("ingress_error", `${request.params.sourceId}:${bodyDigest}:omi`),
          sourceId: request.params.sourceId,
          bodyDigest,
          reasonCode: "INVALID_JSON",
          details: ["Request body is not valid JSON"],
          createdAt: receivedAt,
        });
        return reply.code(400).send({ code: "INVALID_JSON", status: "quarantined" });
      }
      if (!omiAdapter.validate(parsed)) {
        const details = omiAdapter.validationErrors(parsed);
        store.recordIngressError({
          errorId: deterministicId("ingress_error", `${request.params.sourceId}:${bodyDigest}:omi`),
          sourceId: request.params.sourceId,
          bodyDigest,
          reasonCode: "SCHEMA_INVALID",
          details,
          createdAt: receivedAt,
        });
        return reply.code(400).send({ code: "SCHEMA_INVALID", details, status: "quarantined" });
      }
      const [event] = omiAdapter.ingest(parsed, {
        sourceId: request.params.sourceId,
        subject,
        receivedAt,
      });
      if (!event) return reply.code(400).send({ code: "NO_CUE_EVENT", status: "error" });
      const result = store.appendEvent(event);
      return reply.code(result.inserted ? 202 : 200).send({
        event: result.event,
        inserted: result.inserted,
        mode: store.getSourceMode(request.params.sourceId, event.type),
        status: result.inserted ? "accepted" : "duplicate",
      });
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

  server.get("/v1/episodes", () => ({ episodes: store.listEpisodes() }));

  server.get<{ Params: { episodeId: string } }>(
    "/v1/episodes/:episodeId/timeline",
    async (request, reply) => {
      const timeline = store.getEpisodeTimeline(request.params.episodeId);
      return timeline
        ? reply.send({ timeline })
        : reply.code(404).send({ code: "EPISODE_NOT_FOUND", status: "error" });
    },
  );

  server.get<{ Params: { decisionId: string } }>(
    "/v1/decisions/:decisionId",
    async (request, reply) => {
      const decision = store.getDecision(request.params.decisionId);
      return decision
        ? reply.send({ decision })
        : reply.code(404).send({ code: "DECISION_NOT_FOUND", status: "error" });
    },
  );

  server.get<{ Params: { taskId: string } }>("/v1/tasks/:taskId", async (request, reply) => {
    const timeline = store.getTaskTimeline(request.params.taskId);
    return timeline
      ? reply.send({ timeline })
      : reply.code(404).send({ code: "TASK_NOT_FOUND", status: "error" });
  });

  server.get<{ Params: { runtimeRunId: string } }>(
    "/v1/runtime-runs/:runtimeRunId",
    async (request, reply) => {
      const runtimeRun = store.getRuntimeRun(request.params.runtimeRunId);
      return runtimeRun
        ? reply.send({ runtimeRun })
        : reply.code(404).send({ code: "RUNTIME_RUN_NOT_FOUND", status: "error" });
    },
  );

  server.post<{ Body: string }>("/v1/runtime/callbacks/openclaw", async (request, reply) => {
    const secret = process.env["WAKEONCUE_RUNTIME_CALLBACK_SECRET"];
    if (!secret) {
      return reply.code(503).send({ code: "RUNTIME_CALLBACK_SECRET_UNAVAILABLE", status: "error" });
    }
    try {
      verifyWebhookSignature({
        rawBody: request.body,
        timestamp: headerValue(request.headers["x-wakeoncue-timestamp"]),
        signature: headerValue(request.headers["x-wakeoncue-signature"]),
        secret,
        maxClockSkewSeconds: Number(
          process.env["WAKEONCUE_RUNTIME_CALLBACK_CLOCK_SKEW_SECONDS"] ?? "300",
        ),
      });
    } catch (error) {
      const code = error instanceof WebhookSignatureError ? error.code : "SIGNATURE_INVALID";
      return reply.code(401).send({ code, status: "error" });
    }

    let body: unknown;
    try {
      body = parseJson(request.body);
    } catch {
      return reply.code(400).send({ code: "INVALID_JSON", status: "error" });
    }
    if (!Value.Check(RuntimeCallbackSchema, body)) {
      return reply.code(400).send({ code: "SCHEMA_INVALID", status: "error" });
    }
    try {
      const result = store.applyRuntimeCallback(body);
      return reply.code(result.inserted ? 202 : 200).send({
        inserted: result.inserted,
        runtimeRun: result.runtimeRun,
        status: result.inserted ? "accepted" : "duplicate",
      });
    } catch (error) {
      const code = error instanceof Error ? error.message : "RUNTIME_CALLBACK_REJECTED";
      const statusCode = code === "RUNTIME_RUN_NOT_FOUND" ? 404 : 409;
      return reply.code(statusCode).send({ code, status: "error" });
    }
  });

  server.post<{ Body: string }>("/v1/runtime/tool-attempts/openclaw", async (request, reply) => {
    const secret = process.env["WAKEONCUE_RUNTIME_PEP_SECRET"];
    if (!secret) {
      return reply.code(503).send({ code: "RUNTIME_PEP_SECRET_UNAVAILABLE", status: "error" });
    }
    try {
      verifyWebhookSignature({
        rawBody: request.body,
        timestamp: headerValue(request.headers["x-wakeoncue-timestamp"]),
        signature: headerValue(request.headers["x-wakeoncue-signature"]),
        secret,
        maxClockSkewSeconds: Number(
          process.env["WAKEONCUE_RUNTIME_PEP_CLOCK_SKEW_SECONDS"] ?? "60",
        ),
      });
    } catch (error) {
      const code = error instanceof WebhookSignatureError ? error.code : "SIGNATURE_INVALID";
      return reply.code(401).send({ code, status: "error" });
    }
    let body: unknown;
    try {
      body = parseJson(request.body);
    } catch {
      return reply.code(400).send({ code: "INVALID_JSON", status: "error" });
    }
    if (!Value.Check(RuntimeToolAttemptRequestSchema, body)) {
      return reply.code(400).send({ code: "SCHEMA_INVALID", status: "error" });
    }
    try {
      const authorization = store.submitRuntimeToolAttempt(body);
      return reply.code(authorization.decision === "APPROVE_ONCE" ? 202 : 200).send({
        authorization,
        status:
          authorization.decision === "ALLOW"
            ? "authorized"
            : authorization.decision === "APPROVE_ONCE"
              ? "waiting-approval"
              : "denied",
      });
    } catch (error) {
      const code = error instanceof Error ? error.message : "TOOL_ATTEMPT_REJECTED";
      const statusCode = code.endsWith("NOT_FOUND") ? 404 : 409;
      return reply.code(statusCode).send({ code, status: "error" });
    }
  });

  server.post<{ Body: string }>("/v1/runtime/tool-results/openclaw", async (request, reply) => {
    const secret = process.env["WAKEONCUE_RUNTIME_PEP_SECRET"];
    if (!secret) {
      return reply.code(503).send({ code: "RUNTIME_PEP_SECRET_UNAVAILABLE", status: "error" });
    }
    try {
      verifyWebhookSignature({
        rawBody: request.body,
        timestamp: headerValue(request.headers["x-wakeoncue-timestamp"]),
        signature: headerValue(request.headers["x-wakeoncue-signature"]),
        secret,
        maxClockSkewSeconds: Number(
          process.env["WAKEONCUE_RUNTIME_PEP_CLOCK_SKEW_SECONDS"] ?? "60",
        ),
      });
    } catch (error) {
      const code = error instanceof WebhookSignatureError ? error.code : "SIGNATURE_INVALID";
      return reply.code(401).send({ code, status: "error" });
    }
    let body: unknown;
    try {
      body = parseJson(request.body);
    } catch {
      return reply.code(400).send({ code: "INVALID_JSON", status: "error" });
    }
    if (!Value.Check(RuntimeToolResultSchema, body)) {
      return reply.code(400).send({ code: "SCHEMA_INVALID", status: "error" });
    }
    try {
      return reply.send({ attempt: store.recordRuntimeToolResult(body), status: "accepted" });
    } catch (error) {
      const code = error instanceof Error ? error.message : "TOOL_RESULT_REJECTED";
      const statusCode = code.endsWith("NOT_FOUND") ? 404 : 409;
      return reply.code(statusCode).send({ code, status: "error" });
    }
  });

  server.get("/v1/approvals", async (request, reply) => {
    const token = process.env["WAKEONCUE_APPROVAL_ADMIN_TOKEN"];
    if (!token || !bearerMatches(headerValue(request.headers.authorization), token)) {
      return reply.code(401).send({ code: "APPROVAL_AUTH_INVALID", status: "error" });
    }
    return reply.send({
      approvals: store.listToolAttempts("WAITING_APPROVAL").map((attempt) => ({
        ...attempt,
        task: store.getTask(attempt.attempt.taskId),
      })),
    });
  });

  server.get<{ Params: { attemptId: string } }>(
    "/v1/approvals/:attemptId",
    async (request, reply) => {
      const token = process.env["WAKEONCUE_APPROVAL_ADMIN_TOKEN"];
      if (!token || !bearerMatches(headerValue(request.headers.authorization), token)) {
        return reply.code(401).send({ code: "APPROVAL_AUTH_INVALID", status: "error" });
      }
      const attempt = store.getToolAttempt(request.params.attemptId);
      return attempt
        ? reply.send({ attempt: { ...attempt, task: store.getTask(attempt.attempt.taskId) } })
        : reply.code(404).send({ code: "TOOL_ATTEMPT_NOT_FOUND", status: "error" });
    },
  );

  server.post<{ Params: { attemptId: string }; Body: string }>(
    "/v1/approvals/:attemptId",
    async (request, reply) => {
      const token = process.env["WAKEONCUE_APPROVAL_ADMIN_TOKEN"];
      if (!token || !bearerMatches(headerValue(request.headers.authorization), token)) {
        return reply.code(401).send({ code: "APPROVAL_AUTH_INVALID", status: "error" });
      }
      let body: unknown;
      try {
        body = parseJson(request.body);
      } catch {
        return reply.code(400).send({ code: "INVALID_JSON", status: "error" });
      }
      const decision =
        typeof body === "object" && body !== null
          ? (body as Record<string, unknown>)["decision"]
          : undefined;
      if (
        !["APPROVE_ONCE", "DENY"].includes(String(decision)) ||
        typeof body !== "object" ||
        body === null ||
        Object.keys(body).some((key) => key !== "decision")
      ) {
        return reply.code(400).send({ code: "SCHEMA_INVALID", status: "error" });
      }
      try {
        const attempt = store.decideToolApproval(
          request.params.attemptId,
          decision as "APPROVE_ONCE" | "DENY",
        );
        return reply.send({ attempt, status: decision === "APPROVE_ONCE" ? "approved" : "denied" });
      } catch (error) {
        const code = error instanceof Error ? error.message : "APPROVAL_REJECTED";
        const statusCode = code.endsWith("NOT_FOUND") ? 404 : 409;
        return reply.code(statusCode).send({ code, status: "error" });
      }
    },
  );

  server.get<{ Params: { sourceId: string; cueType: string } }>(
    "/v1/source-modes/:sourceId/:cueType",
    (request) => ({
      sourceMode: store.getSourceModeRecord(request.params.sourceId, request.params.cueType),
    }),
  );

  server.get("/v1/source-modes", () => ({ sourceModes: store.listSourceModes() }));

  server.put<{ Params: { sourceId: string; cueType: string }; Body: string }>(
    "/v1/source-modes/:sourceId/:cueType",
    async (request, reply) => {
      if (!isLoopbackAddress(request.ip)) {
        return reply.code(403).send({ code: "LOCAL_ADMIN_ONLY", status: "error" });
      }
      let body: unknown;
      try {
        body = parseJson(request.body);
      } catch {
        return reply.code(400).send({ code: "INVALID_JSON", status: "error" });
      }
      if (typeof body !== "object" || body === null) {
        return reply.code(400).send({ code: "SCHEMA_INVALID", status: "error" });
      }
      const record = body as Record<string, unknown>;
      const mode = record["mode"];
      if (
        !["SHADOW", "NOTIFY", "WAKE"].includes(String(mode)) ||
        Object.keys(record).some((key) => key !== "mode")
      ) {
        return reply.code(400).send({ code: "SCHEMA_INVALID", status: "error" });
      }
      try {
        const sourceMode = store.setSourceMode(
          request.params.sourceId,
          request.params.cueType,
          mode as "SHADOW" | "NOTIFY" | "WAKE",
        );
        return reply.send({ sourceMode });
      } catch (error) {
        if (error instanceof SourceModeGateError) {
          return reply.code(422).send({
            code: "SOURCE_MODE_GATE_NOT_SATISFIED",
            missingRequirements: error.missingRequirements,
            status: "error",
          });
        }
        throw error;
      }
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
