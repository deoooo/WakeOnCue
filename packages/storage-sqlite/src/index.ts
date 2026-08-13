import Database from "better-sqlite3";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import type { AttentionEngine, AttentionEvaluation, SourceMode } from "@wakeoncue/attention";
import type { CueEvent, RuntimeCallback, TaskContract } from "@wakeoncue/contracts";
import {
  canonicalJson,
  deterministicId,
  replayCueEvents,
  sha256,
  type EpisodeProjection,
} from "@wakeoncue/core";
import type { AppendEventResult, EventStore, IngressErrorRecord } from "@wakeoncue/storage";
import type { RuntimeActivationReceipt, RuntimeStatus } from "@wakeoncue/runtime-sdk";

const packageDirectory = dirname(fileURLToPath(import.meta.url));

export function resolveDatabasePath(): string {
  const configuredPath = process.env["WAKEONCUE_DATABASE_PATH"] ?? "./data/wakeoncue.sqlite";
  return configuredPath === ":memory:" ? configuredPath : resolve(process.cwd(), configuredPath);
}

export function openDatabase(databasePath = resolveDatabasePath()): Database.Database {
  const database = new Database(databasePath);
  database.pragma("journal_mode = WAL");
  database.pragma("foreign_keys = ON");
  database.pragma("busy_timeout = 5000");
  return database;
}

export function migrateDatabase(database: Database.Database): string[] {
  database.exec(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version TEXT PRIMARY KEY,
      applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    );
  `);

  const migrationDirectory = resolve(packageDirectory, "migrations");
  const migrations = readdirSync(migrationDirectory)
    .filter((file) => file.endsWith(".sql"))
    .sort();
  const alreadyApplied = database.prepare("SELECT 1 FROM schema_migrations WHERE version = ?");
  const recordMigration = database.prepare("INSERT INTO schema_migrations(version) VALUES (?)");
  const applied: string[] = [];

  for (const migration of migrations) {
    if (alreadyApplied.get(migration)) continue;
    const sql = readFileSync(resolve(migrationDirectory, migration), "utf8");
    database.transaction(() => {
      database.exec(sql);
      recordMigration.run(migration);
    })();
    applied.push(migration);
  }

  return applied;
}

export class IdempotencyConflictError extends Error {
  constructor(readonly idempotencyKey: string) {
    super(`Idempotency key was reused with a different payload: ${idempotencyKey}`);
    this.name = "IdempotencyConflictError";
  }
}

interface EventRow {
  payload_json: string;
  payload_hash: string | null;
}

interface OutboxProjectionRow {
  outbox_id: string;
  aggregate_id: string;
  idempotency_key: string;
}

interface AttentionOutboxRow {
  outbox_id: string;
  aggregate_id: string;
  payload_json: string;
}

interface WakeOutboxRow {
  outbox_id: string;
  aggregate_id: string;
  idempotency_key: string;
}

interface RuntimeRunRow {
  runtime_run_id: string;
  task_id: string;
  adapter: string;
  external_run_id: string | null;
  agent_run_id: string | null;
  status: RuntimeStatus;
  last_observed_at: string | null;
  record_json: string;
}

export interface WakeActivationClaim {
  outboxId: string;
  runtimeRunId: string;
  contract: TaskContract;
  idempotencyKey: string;
  callbackUrl: string;
}

export interface RuntimeRunRecord {
  runtimeRunId: string;
  taskId: string;
  adapter: string;
  externalRunId?: string;
  agentRunId?: string;
  status: RuntimeStatus;
  lastObservedAt?: string;
  record: Record<string, unknown>;
}

export interface TaskRecord {
  taskId: string;
  decisionId: string;
  status: RuntimeStatus;
  contract: TaskContract;
  createdAt: string;
  updatedAt: string;
}

export interface SourceModeGateEvidence {
  shadowDays?: number;
  explicitCommitmentPrecision?: number;
  falseWakeRatePerUserDay?: number;
  privacyViolationCount?: number;
  evidenceRef?: string;
  userExplicitlyEnabled?: boolean;
  runtimeIdempotencyPassed?: boolean;
  pepConformancePassed?: boolean;
  authorizationAttackSuitePassed?: boolean;
  sourcePauseAvailable?: boolean;
}

export interface SourceModeRecord {
  sourceId: string;
  cueType: string;
  mode: SourceMode;
  gateEvidence: SourceModeGateEvidence;
  updatedAt: string;
}

export class SourceModeGateError extends Error {
  constructor(readonly missingRequirements: string[]) {
    super(`Source mode gate is not satisfied: ${missingRequirements.join(", ")}`);
    this.name = "SourceModeGateError";
  }
}

function validateModeGate(mode: SourceMode, evidence: SourceModeGateEvidence): void {
  if (mode === "SHADOW") return;
  const missing = [
    ...(typeof evidence.shadowDays === "number" && evidence.shadowDays >= 7
      ? []
      : ["SHADOW_DAYS_7"]),
    ...(typeof evidence.explicitCommitmentPrecision === "number" &&
    evidence.explicitCommitmentPrecision >= 0.9
      ? []
      : ["PRECISION_0_90"]),
    ...(typeof evidence.falseWakeRatePerUserDay === "number" &&
    evidence.falseWakeRatePerUserDay <= 0.2
      ? []
      : ["FALSE_WAKE_RATE_0_20"]),
    ...(evidence.privacyViolationCount === 0 ? [] : ["PRIVACY_VIOLATIONS_ZERO"]),
    ...(evidence.evidenceRef ? [] : ["SHADOW_EVIDENCE_REF"]),
  ];
  if (mode === "WAKE") {
    missing.push(
      ...(evidence.userExplicitlyEnabled ? [] : ["USER_EXPLICIT_ENABLE"]),
      ...(evidence.runtimeIdempotencyPassed ? [] : ["RUNTIME_IDEMPOTENCY"]),
      ...(evidence.pepConformancePassed ? [] : ["PEP_CONFORMANCE"]),
      ...(evidence.authorizationAttackSuitePassed ? [] : ["AUTHORIZATION_ATTACK_SUITE"]),
      ...(evidence.sourcePauseAvailable ? [] : ["SOURCE_PAUSE_AVAILABLE"]),
    );
  }
  if (missing.length > 0) throw new SourceModeGateError(missing);
}

function idempotencyPayloadHash(event: CueEvent): string {
  return sha256(canonicalJson({ ...event, receivedAt: "<ingress-received-at>" }));
}

function normalizeTaskDeadline(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const dateOnly = /^\d{4}-\d{2}-\d{2}$/u.exec(value);
  if (dateOnly) return `${value}T23:59:59.000Z`;
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? undefined : parsed.toISOString();
}

function buildTaskContract(
  evaluation: AttentionEvaluation,
  episode: EpisodeProjection,
  adapter: string,
): TaskContract {
  const taskId = deterministicId("task", evaluation.decision.decisionId);
  const commitment = evaluation.signals.commitment ?? "the accepted cue";
  const deadline = normalizeTaskDeadline(evaluation.signals.deadline);
  return {
    contractVersion: "wakeoncue.task/v1",
    taskId,
    subject: episode.subject,
    goal: `Follow through on this commitment: ${commitment}`,
    successCriteria: [
      "Produce a concrete outcome or report a specific blocker",
      "Attach verifiable evidence for any claimed result",
    ],
    constraints: [
      "Do not perform external writes without a WakeOnCue one-time permit",
      "Do not treat agent text alone as proof that an external side effect happened",
      "Stay within the initial capability scope",
    ],
    contextRefs: [
      `wakeoncue://decisions/${evaluation.decision.decisionId}`,
      `wakeoncue://episodes/${episode.episodeId}`,
      ...evaluation.decision.evidenceRefs,
    ],
    ...(deadline ? { deadline } : {}),
    runtime: { adapter, profile: "default" },
    capabilityScope: ["task.plan", "evidence.read"],
    approvalRequiredFor: [
      "external.send",
      "external.write",
      "file.write",
      "calendar.write",
      "task.write",
    ],
    idempotencyKey: `wake:${evaluation.decision.decisionId}:v1`,
  };
}

const terminalRuntimeStatuses = new Set<RuntimeStatus>(["SUCCEEDED", "FAILED", "CANCELLED"]);

function canApplyRuntimeTransition(current: RuntimeStatus, next: RuntimeStatus): boolean {
  if (current === next) return true;
  if (terminalRuntimeStatuses.has(current)) return false;
  if (current === "UNKNOWN") {
    return ["RECONCILING", "SUCCEEDED", "FAILED", "CANCELLED"].includes(next);
  }
  return next !== "RUN_ACCEPTED" || current === "RECONCILING";
}

function runtimeRunRecord(row: RuntimeRunRow): RuntimeRunRecord {
  return {
    runtimeRunId: row.runtime_run_id,
    taskId: row.task_id,
    adapter: row.adapter,
    ...(row.external_run_id ? { externalRunId: row.external_run_id } : {}),
    ...(row.agent_run_id ? { agentRunId: row.agent_run_id } : {}),
    status: row.status,
    ...(row.last_observed_at ? { lastObservedAt: row.last_observed_at } : {}),
    record: JSON.parse(row.record_json) as Record<string, unknown>,
  };
}

export class SqliteWakeStore implements EventStore {
  constructor(readonly database: Database.Database) {}

  appendEvent(event: CueEvent): AppendEventResult {
    const payloadJson = canonicalJson(event);
    const payloadHash = idempotencyPayloadHash(event);
    return this.database.transaction(() => {
      const existing = this.database
        .prepare("SELECT payload_json, payload_hash FROM events WHERE idempotency_key = ?")
        .get(event.idempotencyKey) as EventRow | undefined;
      if (existing) {
        const existingHash = idempotencyPayloadHash(JSON.parse(existing.payload_json) as CueEvent);
        if (existingHash !== payloadHash) throw new IdempotencyConflictError(event.idempotencyKey);
        return { event: JSON.parse(existing.payload_json) as CueEvent, inserted: false };
      }

      this.database
        .prepare(
          `INSERT INTO events(
            event_id, spec_version, event_type, subject, source_adapter, source_id,
            correlation_id, occurred_at, received_at, idempotency_key, payload_json, payload_hash
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(
          event.eventId,
          event.specVersion,
          event.type,
          event.subject,
          event.source.adapter,
          event.source.sourceId,
          event.correlationId,
          event.occurredAt,
          event.receivedAt,
          event.idempotencyKey,
          payloadJson,
          payloadHash,
        );
      this.database
        .prepare(
          "INSERT INTO event_payloads(event_id, encrypted_payload, evidence_refs_json) VALUES (?, NULL, ?)",
        )
        .run(event.eventId, canonicalJson(event.evidenceRefs));
      this.database
        .prepare(
          `INSERT INTO outbox(
            outbox_id, topic, aggregate_id, idempotency_key, payload_json, status, available_at
          ) VALUES (?, 'event.project', ?, ?, ?, 'PENDING', ?)`,
        )
        .run(
          `outbox_${event.eventId}`,
          event.eventId,
          `project:${event.eventId}:v1`,
          canonicalJson({ eventId: event.eventId }),
          event.receivedAt,
        );
      return { event, inserted: true };
    })();
  }

  getEvent(eventId: string): CueEvent | undefined {
    const row = this.database
      .prepare("SELECT payload_json FROM events WHERE event_id = ?")
      .get(eventId) as Pick<EventRow, "payload_json"> | undefined;
    return row ? (JSON.parse(row.payload_json) as CueEvent) : undefined;
  }

  getEvents(eventIds?: readonly string[]): CueEvent[] {
    if (eventIds && eventIds.length === 0) return [];
    const rows = eventIds
      ? (this.database
          .prepare(
            `SELECT payload_json FROM events WHERE event_id IN (${eventIds.map(() => "?").join(",")})`,
          )
          .all(...eventIds) as Array<Pick<EventRow, "payload_json">>)
      : (this.database
          .prepare("SELECT payload_json FROM events ORDER BY occurred_at, received_at, event_id")
          .all() as Array<Pick<EventRow, "payload_json">>);
    const events = rows.map((row) => JSON.parse(row.payload_json) as CueEvent);
    const positions = new Map(eventIds?.map((id, index) => [id, index]));
    return positions
      ? events.sort(
          (left, right) =>
            (positions.get(left.eventId) ?? Number.MAX_SAFE_INTEGER) -
            (positions.get(right.eventId) ?? Number.MAX_SAFE_INTEGER),
        )
      : events;
  }

  recordIngressError(record: IngressErrorRecord): void {
    this.database
      .prepare(
        `INSERT OR IGNORE INTO ingress_errors(
          error_id, source_id, body_digest, idempotency_key, reason_code, details_json, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        record.errorId,
        record.sourceId,
        record.bodyDigest,
        record.idempotencyKey ?? null,
        record.reasonCode,
        canonicalJson(record.details),
        record.createdAt,
      );
  }

  processProjectionOutbox(limit = 50): number {
    const rows = this.database
      .prepare(
        `SELECT outbox_id, aggregate_id, idempotency_key
         FROM outbox
         WHERE topic = 'event.project' AND status = 'PENDING' AND available_at <= ?
         ORDER BY available_at, outbox_id
         LIMIT ?`,
      )
      .all(new Date().toISOString(), limit) as OutboxProjectionRow[];

    for (const row of rows) {
      this.database.transaction(() => {
        const event = this.getEvent(row.aggregate_id);
        if (!event) throw new Error(`Outbox references missing event ${row.aggregate_id}`);
        const relatedRows = this.database
          .prepare(
            `SELECT payload_json FROM events
             WHERE subject = ? AND correlation_id = ?
             ORDER BY occurred_at, received_at, event_id`,
          )
          .all(event.subject, event.correlationId) as Array<Pick<EventRow, "payload_json">>;
        const projection = replayCueEvents(
          relatedRows.map((related) => JSON.parse(related.payload_json) as CueEvent),
        ).episodes[0];
        if (!projection) throw new Error(`Projection is empty for ${event.eventId}`);
        const now = new Date().toISOString();
        this.database
          .prepare(
            `INSERT INTO episodes(episode_id, subject, correlation_key, state_json, version, updated_at)
             VALUES (?, ?, ?, ?, 1, ?)
             ON CONFLICT(episode_id) DO UPDATE SET
               state_json = excluded.state_json,
               version = episodes.version + 1,
               updated_at = excluded.updated_at`,
          )
          .run(
            projection.episodeId,
            projection.subject,
            projection.correlationId,
            canonicalJson(projection),
            now,
          );
        this.database
          .prepare(
            `INSERT INTO deliveries(
              delivery_id, consumer, idempotency_key, external_ref, status,
              record_json, created_at, updated_at
            ) VALUES (?, 'projector-v1', ?, ?, 'DELIVERED', ?, ?, ?)
            ON CONFLICT(consumer, idempotency_key) DO NOTHING`,
          )
          .run(
            `delivery_${row.outbox_id}`,
            row.idempotency_key,
            projection.episodeId,
            canonicalJson({ eventId: event.eventId, episodeId: projection.episodeId }),
            now,
            now,
          );
        const attentionKey = `attention:${projection.episodeId}:${projection.eventIds.length}:v1`;
        this.database
          .prepare(
            `INSERT INTO outbox(
              outbox_id, topic, aggregate_id, idempotency_key, payload_json, status, available_at
            ) VALUES (?, 'episode.attention', ?, ?, ?, 'PENDING', ?)
            ON CONFLICT(idempotency_key) DO NOTHING`,
          )
          .run(
            `outbox_attention_${sha256(attentionKey).slice(0, 26)}`,
            projection.episodeId,
            attentionKey,
            canonicalJson({
              episodeId: projection.episodeId,
              eventIds: projection.eventIds,
              sourceId: event.source.sourceId,
              cueType: event.type,
            }),
            now,
          );
        this.database
          .prepare("UPDATE outbox SET status = 'COMPLETED', completed_at = ? WHERE outbox_id = ?")
          .run(now, row.outbox_id);
      })();
    }
    return rows.length;
  }

  getSourceMode(sourceId: string, cueType: string): SourceMode {
    const row = this.database
      .prepare("SELECT mode FROM source_modes WHERE source_id = ? AND cue_type = ?")
      .get(sourceId, cueType) as { mode: SourceMode } | undefined;
    return row?.mode ?? "SHADOW";
  }

  getSourceModeRecord(sourceId: string, cueType: string): SourceModeRecord {
    const row = this.database
      .prepare(
        `SELECT source_id, cue_type, mode, gate_evidence_json, updated_at
         FROM source_modes WHERE source_id = ? AND cue_type = ?`,
      )
      .get(sourceId, cueType) as
      | {
          source_id: string;
          cue_type: string;
          mode: SourceMode;
          gate_evidence_json: string;
          updated_at: string;
        }
      | undefined;
    return row
      ? {
          sourceId: row.source_id,
          cueType: row.cue_type,
          mode: row.mode,
          gateEvidence: JSON.parse(row.gate_evidence_json) as SourceModeGateEvidence,
          updatedAt: row.updated_at,
        }
      : {
          sourceId,
          cueType,
          mode: "SHADOW",
          gateEvidence: {},
          updatedAt: "",
        };
  }

  setSourceMode(sourceId: string, cueType: string, mode: SourceMode): SourceModeRecord {
    const evidenceRow = this.database
      .prepare(
        `SELECT evidence_json FROM source_gate_evidence
         WHERE source_id = ? AND cue_type = ?`,
      )
      .get(sourceId, cueType) as { evidence_json: string } | undefined;
    const gateEvidence = evidenceRow
      ? (JSON.parse(evidenceRow.evidence_json) as SourceModeGateEvidence)
      : {};
    validateModeGate(mode, gateEvidence);
    const now = new Date().toISOString();
    this.database
      .prepare(
        `INSERT INTO source_modes(source_id, cue_type, mode, gate_evidence_json, updated_at)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(source_id, cue_type) DO UPDATE SET
           mode = excluded.mode,
           gate_evidence_json = excluded.gate_evidence_json,
           updated_at = excluded.updated_at`,
      )
      .run(sourceId, cueType, mode, canonicalJson(gateEvidence), now);
    return this.getSourceModeRecord(sourceId, cueType);
  }

  recordSourceGateEvidence(
    sourceId: string,
    cueType: string,
    evidence: SourceModeGateEvidence,
    calculatedAt = new Date().toISOString(),
  ): void {
    this.database
      .prepare(
        `INSERT INTO source_gate_evidence(source_id, cue_type, evidence_json, calculated_at)
         VALUES (?, ?, ?, ?)
         ON CONFLICT(source_id, cue_type) DO UPDATE SET
           evidence_json = excluded.evidence_json,
           calculated_at = excluded.calculated_at`,
      )
      .run(sourceId, cueType, canonicalJson(evidence), calculatedAt);
  }

  listSourceModes(): SourceModeRecord[] {
    const rows = this.database
      .prepare(
        `SELECT source_id, cue_type, mode, gate_evidence_json, updated_at
         FROM source_modes ORDER BY source_id, cue_type`,
      )
      .all() as Array<{
      source_id: string;
      cue_type: string;
      mode: SourceMode;
      gate_evidence_json: string;
      updated_at: string;
    }>;
    return rows.map((row) => ({
      sourceId: row.source_id,
      cueType: row.cue_type,
      mode: row.mode,
      gateEvidence: JSON.parse(row.gate_evidence_json) as SourceModeGateEvidence,
      updatedAt: row.updated_at,
    }));
  }

  async processAttentionOutbox(engine: AttentionEngine, limit = 20): Promise<number> {
    const rows = this.database
      .prepare(
        `SELECT outbox_id, aggregate_id, payload_json
         FROM outbox
         WHERE topic = 'episode.attention' AND status = 'PENDING' AND available_at <= ?
         ORDER BY available_at, outbox_id
         LIMIT ?`,
      )
      .all(new Date().toISOString(), limit) as AttentionOutboxRow[];

    let processed = 0;
    for (const row of rows) {
      const episode = this.getEpisode(row.aggregate_id);
      if (!episode)
        throw new Error(`Attention outbox references missing episode ${row.aggregate_id}`);
      const payload = JSON.parse(row.payload_json) as {
        eventIds: string[];
        sourceId: string;
        cueType: string;
      };
      const events = this.getEvents(payload.eventIds);
      const evaluationTime = events.at(-1)?.receivedAt ?? episode.lastOccurredAt;
      const usageDate = evaluationTime.slice(0, 10);
      const usage = this.database
        .prepare(
          `SELECT wake_count, notification_count FROM attention_daily_usage
           WHERE subject = ? AND usage_date = ?`,
        )
        .get(episode.subject, usageDate) as
        { wake_count: number; notification_count: number } | undefined;
      const cooldownRows = this.database
        .prepare(
          `SELECT DISTINCT cooldown_key FROM decisions
           WHERE subject = ? AND cooldown_key IS NOT NULL AND expires_at > ?
             AND decision = 'WAKE_AGENT'`,
        )
        .all(episode.subject, evaluationTime) as Array<{ cooldown_key: string }>;
      const evaluation = await engine.decide({
        episode,
        events,
        sourceId: payload.sourceId,
        cueType: payload.cueType,
        mode: this.getSourceMode(payload.sourceId, payload.cueType),
        evaluationTime,
        timezoneOffsetMinutes: Number(process.env["WAKEONCUE_TIMEZONE_OFFSET_MINUTES"] ?? "480"),
        quietHours: {
          startHour: Number(process.env["WAKEONCUE_QUIET_START_HOUR"] ?? "22"),
          endHour: Number(process.env["WAKEONCUE_QUIET_END_HOUR"] ?? "7"),
        },
        dailyBudget: {
          wakeLimit: Number(process.env["WAKEONCUE_DAILY_WAKE_LIMIT"] ?? "3"),
          notifyLimit: Number(process.env["WAKEONCUE_DAILY_NOTIFICATION_LIMIT"] ?? "5"),
          wakesUsed: usage?.wake_count ?? 0,
          notificationsUsed: usage?.notification_count ?? 0,
        },
        activeCooldownKeys: cooldownRows.map((entry) => entry.cooldown_key),
      });

      this.database.transaction(() => {
        const inserted = this.database
          .prepare(
            `INSERT OR IGNORE INTO decisions(
              decision_id, episode_id, decision, reason_codes_json, evidence_refs_json,
              strategy_version, model_ref, record_json, created_at, subject, source_id,
              cue_type, mode, disposition, cooldown_key, expires_at, episode_version
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          )
          .run(
            evaluation.decision.decisionId,
            episode.episodeId,
            evaluation.decision.decision,
            canonicalJson(evaluation.decision.reasonCodes),
            canonicalJson(evaluation.decision.evidenceRefs),
            evaluation.decision.strategyVersion,
            evaluation.decision.modelRef ?? null,
            canonicalJson(evaluation),
            evaluationTime,
            episode.subject,
            payload.sourceId,
            payload.cueType,
            evaluation.mode,
            evaluation.disposition,
            evaluation.decision.cooldownKey,
            evaluation.decision.expiresAt,
            episode.eventIds.length,
          ).changes;

        if (inserted > 0 && evaluation.disposition === "WAKE_QUEUED") {
          this.incrementAttentionUsage(episode.subject, usageDate, "wake_count", evaluationTime);
          this.enqueueAttentionEffect("wake.activate", evaluation, evaluationTime);
        } else if (inserted > 0 && evaluation.disposition === "NOTIFICATION_QUEUED") {
          this.incrementAttentionUsage(
            episode.subject,
            usageDate,
            "notification_count",
            evaluationTime,
          );
          this.enqueueAttentionEffect("attention.notify", evaluation, evaluationTime);
        }
        if (inserted > 0 && evaluation.observationRequest) {
          const observation = evaluation.observationRequest;
          this.database
            .prepare(
              `INSERT OR IGNORE INTO observation_requests(
                observation_id, episode_id, capability, purpose, scope_json,
                budget_json, expires_at, status
              ) VALUES (?, ?, ?, ?, ?, ?, ?, 'PENDING')`,
            )
            .run(
              deterministicId("observation", evaluation.decision.decisionId),
              episode.episodeId,
              observation.capability,
              observation.purpose,
              canonicalJson({ dataScope: observation.dataScope }),
              canonicalJson({ maxCost: observation.maxCost, retention: observation.retention }),
              new Date(
                new Date(evaluationTime).getTime() + observation.ttlSeconds * 1_000,
              ).toISOString(),
            );
        }
        if (inserted > 0) {
          this.upsertExtractedEntities(episode.episodeId, evaluation, evaluationTime);
        }
        this.database
          .prepare("UPDATE outbox SET status = 'COMPLETED', completed_at = ? WHERE outbox_id = ?")
          .run(evaluationTime, row.outbox_id);
      })();
      processed += 1;
    }
    return processed;
  }

  private incrementAttentionUsage(
    subject: string,
    usageDate: string,
    field: "wake_count" | "notification_count",
    now: string,
  ): void {
    this.database
      .prepare(
        `INSERT INTO attention_daily_usage(subject, usage_date, ${field}, updated_at)
         VALUES (?, ?, 1, ?)
         ON CONFLICT(subject, usage_date) DO UPDATE SET
           ${field} = ${field} + 1,
           updated_at = excluded.updated_at`,
      )
      .run(subject, usageDate, now);
  }

  private upsertExtractedEntities(
    episodeId: string,
    evaluation: AttentionEvaluation,
    now: string,
  ): void {
    const entities = [
      ["commitment", evaluation.signals.commitment],
      ["deadline", evaluation.signals.deadline],
      ["recipient", evaluation.signals.recipient],
    ] as const;
    for (const [type, value] of entities) {
      if (!value) continue;
      this.database
        .prepare(
          `INSERT INTO entities(entity_id, episode_id, entity_type, value_json, updated_at)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(entity_id) DO UPDATE SET
             value_json = excluded.value_json,
             updated_at = excluded.updated_at`,
        )
        .run(
          deterministicId("entity", `${episodeId}:${type}`),
          episodeId,
          type,
          canonicalJson({ value }),
          now,
        );
    }
  }

  private enqueueAttentionEffect(
    topic: "attention.notify" | "wake.activate",
    evaluation: AttentionEvaluation,
    now: string,
  ): void {
    const key = `${topic}:${evaluation.decision.decisionId}`;
    this.database
      .prepare(
        `INSERT INTO outbox(
          outbox_id, topic, aggregate_id, idempotency_key, payload_json, status, available_at
        ) VALUES (?, ?, ?, ?, ?, 'PENDING', ?)
        ON CONFLICT(idempotency_key) DO NOTHING`,
      )
      .run(
        `outbox_effect_${sha256(key).slice(0, 26)}`,
        topic,
        evaluation.decision.decisionId,
        key,
        canonicalJson({ decisionId: evaluation.decision.decisionId }),
        now,
      );
  }

  claimWakeActivation(adapter: string, callbackUrl: string): WakeActivationClaim | undefined {
    const row = this.database
      .prepare(
        `SELECT outbox_id, aggregate_id, idempotency_key
         FROM outbox
         WHERE topic = 'wake.activate' AND status = 'PENDING' AND available_at <= ?
         ORDER BY available_at, outbox_id
         LIMIT 1`,
      )
      .get(new Date().toISOString()) as WakeOutboxRow | undefined;
    if (!row) return undefined;

    return this.database.transaction(() => {
      const claimedAt = new Date().toISOString();
      const claimed = this.database
        .prepare(
          `UPDATE outbox SET status = 'PROCESSING', claimed_at = ?
           WHERE outbox_id = ? AND status = 'PENDING'`,
        )
        .run(claimedAt, row.outbox_id).changes;
      if (claimed === 0) return undefined;

      const evaluation = this.getDecision(row.aggregate_id);
      if (!evaluation)
        throw new Error(`Wake outbox references missing decision ${row.aggregate_id}`);
      const episode = this.getEpisode(evaluation.decision.episodeId);
      if (!episode) {
        throw new Error(
          `Wake decision references missing episode ${evaluation.decision.episodeId}`,
        );
      }
      const contract = buildTaskContract(evaluation, episode, adapter);
      const runtimeRunId = deterministicId(
        "run",
        `${contract.taskId}:${adapter}:${contract.runtime.profile}`,
      );
      this.database
        .prepare(
          `INSERT INTO tasks(
            task_id, decision_id, idempotency_key, contract_json, status, created_at, updated_at
          ) VALUES (?, ?, ?, ?, 'RECONCILING', ?, ?)
          ON CONFLICT(idempotency_key) DO NOTHING`,
        )
        .run(
          contract.taskId,
          evaluation.decision.decisionId,
          contract.idempotencyKey,
          canonicalJson(contract),
          claimedAt,
          claimedAt,
        );
      this.database
        .prepare(
          `INSERT INTO runtime_runs(
            runtime_run_id, task_id, adapter, external_run_id, idempotency_key,
            status, last_observed_at, record_json
          ) VALUES (?, ?, ?, NULL, ?, 'RECONCILING', ?, ?)
          ON CONFLICT(idempotency_key) DO NOTHING`,
        )
        .run(
          runtimeRunId,
          contract.taskId,
          adapter,
          contract.idempotencyKey,
          claimedAt,
          canonicalJson({
            phase: "ACTIVATION_DISPATCHING",
            callbackUrl,
            sourceOutboxId: row.outbox_id,
          }),
        );
      this.database
        .prepare(
          `INSERT INTO deliveries(
            delivery_id, consumer, idempotency_key, external_ref, status,
            record_json, created_at, updated_at
          ) VALUES (?, ?, ?, NULL, 'DISPATCHING', ?, ?, ?)
          ON CONFLICT(consumer, idempotency_key) DO NOTHING`,
        )
        .run(
          deterministicId("delivery", `runtime:${adapter}:${contract.idempotencyKey}`),
          `runtime:${adapter}`,
          contract.idempotencyKey,
          canonicalJson({ runtimeRunId, taskId: contract.taskId }),
          claimedAt,
          claimedAt,
        );
      return {
        outboxId: row.outbox_id,
        runtimeRunId,
        contract,
        idempotencyKey: contract.idempotencyKey,
        callbackUrl,
      };
    })();
  }

  completeWakeActivation(
    claim: WakeActivationClaim,
    receipt: RuntimeActivationReceipt,
  ): RuntimeRunRecord {
    return this.database.transaction(() => {
      const row = this.getRuntimeRunRow(claim.runtimeRunId);
      if (!row) throw new Error(`Runtime run ${claim.runtimeRunId} does not exist`);
      if (row.external_run_id && row.external_run_id !== receipt.externalRunId) {
        throw new Error("RUNTIME_EXTERNAL_RUN_ID_MISMATCH");
      }
      const now = new Date().toISOString();
      const observedAt = receipt.acceptedAt;
      const status = canApplyRuntimeTransition(row.status, receipt.status)
        ? receipt.status
        : row.status;
      const record = {
        ...(JSON.parse(row.record_json) as Record<string, unknown>),
        activationReceipt: receipt,
        phase: "ACTIVATION_ACCEPTED",
      };
      this.database
        .prepare(
          `UPDATE runtime_runs SET external_run_id = ?, status = ?, last_observed_at = ?, record_json = ?
           WHERE runtime_run_id = ?`,
        )
        .run(receipt.externalRunId, status, observedAt, canonicalJson(record), claim.runtimeRunId);
      this.database
        .prepare("UPDATE tasks SET status = ?, updated_at = ? WHERE task_id = ?")
        .run(status, now, claim.contract.taskId);
      this.database
        .prepare(
          `UPDATE deliveries SET external_ref = ?, status = 'DELIVERED', record_json = ?, updated_at = ?
           WHERE consumer = ? AND idempotency_key = ?`,
        )
        .run(
          receipt.externalRunId,
          canonicalJson({ receipt, runtimeRunId: claim.runtimeRunId }),
          now,
          `runtime:${claim.contract.runtime.adapter}`,
          claim.idempotencyKey,
        );
      this.database
        .prepare("UPDATE outbox SET status = 'COMPLETED', completed_at = ? WHERE outbox_id = ?")
        .run(now, claim.outboxId);
      const updated = this.getRuntimeRunRow(claim.runtimeRunId);
      if (!updated) throw new Error("Runtime run disappeared after activation");
      return runtimeRunRecord(updated);
    })();
  }

  failWakeActivation(
    claim: WakeActivationClaim,
    error: string,
    outcomeUncertain: boolean,
  ): RuntimeRunRecord {
    return this.database.transaction(() => {
      const status: RuntimeStatus = outcomeUncertain ? "UNKNOWN" : "FAILED";
      const now = new Date().toISOString();
      const row = this.getRuntimeRunRow(claim.runtimeRunId);
      if (!row) throw new Error(`Runtime run ${claim.runtimeRunId} does not exist`);
      const record = {
        ...(JSON.parse(row.record_json) as Record<string, unknown>),
        activationError: error,
        outcomeUncertain,
        phase: outcomeUncertain ? "ACTIVATION_OUTCOME_UNKNOWN" : "ACTIVATION_FAILED",
      };
      this.database
        .prepare(
          `UPDATE runtime_runs SET status = ?, last_observed_at = ?, record_json = ?
           WHERE runtime_run_id = ?`,
        )
        .run(status, now, canonicalJson(record), claim.runtimeRunId);
      this.database
        .prepare("UPDATE tasks SET status = ?, updated_at = ? WHERE task_id = ?")
        .run(status, now, claim.contract.taskId);
      this.database
        .prepare(
          `UPDATE deliveries SET status = ?, record_json = ?, updated_at = ?
           WHERE consumer = ? AND idempotency_key = ?`,
        )
        .run(
          status,
          canonicalJson({ error, outcomeUncertain, runtimeRunId: claim.runtimeRunId }),
          now,
          `runtime:${claim.contract.runtime.adapter}`,
          claim.idempotencyKey,
        );
      this.database
        .prepare(
          `UPDATE outbox SET status = 'COMPLETED', completed_at = ?, last_error = ?
           WHERE outbox_id = ?`,
        )
        .run(now, error, claim.outboxId);
      const updated = this.getRuntimeRunRow(claim.runtimeRunId);
      if (!updated) throw new Error("Runtime run disappeared after activation failure");
      return runtimeRunRecord(updated);
    })();
  }

  applyRuntimeCallback(
    callback: RuntimeCallback,
    receivedAt = new Date().toISOString(),
  ): { inserted: boolean; runtimeRun: RuntimeRunRecord } {
    return this.database.transaction(() => {
      const row = this.getRuntimeRunRow(callback.runtimeRunId);
      if (!row) throw new Error("RUNTIME_RUN_NOT_FOUND");
      if (row.task_id !== callback.taskId) throw new Error("RUNTIME_TASK_MISMATCH");
      if (row.agent_run_id && row.agent_run_id !== callback.agentRunId) {
        throw new Error("RUNTIME_AGENT_RUN_ID_MISMATCH");
      }
      const payloadDigest = `sha256:${sha256(canonicalJson(callback))}`;
      const callbackEventId = deterministicId(
        "callback",
        `${callback.runtimeRunId}:${payloadDigest}`,
      );
      const inserted =
        this.database
          .prepare(
            `INSERT OR IGNORE INTO runtime_callback_events(
              callback_event_id, runtime_run_id, agent_run_id, status, payload_digest,
              record_json, occurred_at, received_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
          )
          .run(
            callbackEventId,
            callback.runtimeRunId,
            callback.agentRunId,
            callback.status,
            payloadDigest,
            canonicalJson(callback),
            callback.occurredAt,
            receivedAt,
          ).changes > 0;

      if (inserted) {
        const isOlder = row.last_observed_at !== null && callback.occurredAt < row.last_observed_at;
        const nextStatus =
          !isOlder && canApplyRuntimeTransition(row.status, callback.status)
            ? callback.status
            : row.status;
        const record = {
          ...(JSON.parse(row.record_json) as Record<string, unknown>),
          lastCallback: callback,
          phase: `CALLBACK_${callback.status}`,
        };
        this.database
          .prepare(
            `UPDATE runtime_runs SET agent_run_id = COALESCE(agent_run_id, ?),
               status = ?, last_observed_at = ?, record_json = ?
             WHERE runtime_run_id = ?`,
          )
          .run(
            callback.agentRunId,
            nextStatus,
            isOlder ? row.last_observed_at : callback.occurredAt,
            canonicalJson(record),
            callback.runtimeRunId,
          );
        this.database
          .prepare("UPDATE tasks SET status = ?, updated_at = ? WHERE task_id = ?")
          .run(nextStatus, receivedAt, callback.taskId);
      }
      const updated = this.getRuntimeRunRow(callback.runtimeRunId);
      if (!updated) throw new Error("Runtime run disappeared after callback");
      return { inserted, runtimeRun: runtimeRunRecord(updated) };
    })();
  }

  markStaleRuntimeActivationsUnknown(
    staleBefore: string,
    observedAt = new Date().toISOString(),
  ): number {
    const rows = this.database
      .prepare(
        `SELECT o.outbox_id, r.runtime_run_id, r.task_id, r.adapter, r.idempotency_key
         FROM outbox o
         JOIN runtime_runs r ON json_extract(r.record_json, '$.sourceOutboxId') = o.outbox_id
         WHERE o.topic = 'wake.activate' AND o.status = 'PROCESSING' AND o.claimed_at < ?`,
      )
      .all(staleBefore) as Array<{
      outbox_id: string;
      runtime_run_id: string;
      task_id: string;
      adapter: string;
      idempotency_key: string;
    }>;
    for (const row of rows) {
      this.database.transaction(() => {
        this.database
          .prepare(
            `UPDATE runtime_runs SET status = 'UNKNOWN', last_observed_at = ?,
               record_json = json_set(record_json, '$.phase', 'STALE_ACTIVATION_UNKNOWN')
             WHERE runtime_run_id = ? AND status = 'RECONCILING'`,
          )
          .run(observedAt, row.runtime_run_id);
        this.database
          .prepare("UPDATE tasks SET status = 'UNKNOWN', updated_at = ? WHERE task_id = ?")
          .run(observedAt, row.task_id);
        this.database
          .prepare(
            `UPDATE deliveries SET status = 'UNKNOWN', updated_at = ?
             WHERE consumer = ? AND idempotency_key = ?`,
          )
          .run(observedAt, `runtime:${row.adapter}`, row.idempotency_key);
        this.database
          .prepare(
            `UPDATE outbox SET status = 'COMPLETED', completed_at = ?,
               last_error = 'ACTIVATION_INTERRUPTED_OUTCOME_UNKNOWN'
             WHERE outbox_id = ?`,
          )
          .run(observedAt, row.outbox_id);
      })();
    }
    return rows.length;
  }

  markStaleRuntimeRunsUnknown(staleBefore: string, observedAt = new Date().toISOString()): number {
    const rows = this.database
      .prepare(
        `SELECT runtime_run_id, task_id, record_json
         FROM runtime_runs
         WHERE status IN ('RUN_ACCEPTED', 'RUNNING', 'RECONCILING')
           AND last_observed_at < ?`,
      )
      .all(staleBefore) as Array<{
      runtime_run_id: string;
      task_id: string;
      record_json: string;
    }>;
    for (const row of rows) {
      this.database.transaction(() => {
        const record = {
          ...(JSON.parse(row.record_json) as Record<string, unknown>),
          phase: "RUNTIME_CALLBACK_STALE_UNKNOWN",
          reconciliationRequired: true,
        };
        this.database
          .prepare(
            `UPDATE runtime_runs SET status = 'UNKNOWN', last_observed_at = ?, record_json = ?
             WHERE runtime_run_id = ? AND status IN ('RUN_ACCEPTED', 'RUNNING', 'RECONCILING')`,
          )
          .run(observedAt, canonicalJson(record), row.runtime_run_id);
        this.database
          .prepare("UPDATE tasks SET status = 'UNKNOWN', updated_at = ? WHERE task_id = ?")
          .run(observedAt, row.task_id);
      })();
    }
    return rows.length;
  }

  getTask(taskId: string): TaskRecord | undefined {
    const row = this.database
      .prepare(
        `SELECT task_id, decision_id, contract_json, status, created_at, updated_at
         FROM tasks WHERE task_id = ?`,
      )
      .get(taskId) as
      | {
          task_id: string;
          decision_id: string;
          contract_json: string;
          status: RuntimeStatus;
          created_at: string;
          updated_at: string;
        }
      | undefined;
    return row
      ? {
          taskId: row.task_id,
          decisionId: row.decision_id,
          status: row.status,
          contract: JSON.parse(row.contract_json) as TaskContract,
          createdAt: row.created_at,
          updatedAt: row.updated_at,
        }
      : undefined;
  }

  getRuntimeRun(runtimeRunId: string): RuntimeRunRecord | undefined {
    const row = this.getRuntimeRunRow(runtimeRunId);
    return row ? runtimeRunRecord(row) : undefined;
  }

  getTaskTimeline(taskId: string):
    | {
        task: TaskRecord;
        runtimeRuns: RuntimeRunRecord[];
        callbacks: RuntimeCallback[];
      }
    | undefined {
    const task = this.getTask(taskId);
    if (!task) return undefined;
    const runRows = this.database
      .prepare("SELECT * FROM runtime_runs WHERE task_id = ? ORDER BY runtime_run_id")
      .all(taskId) as RuntimeRunRow[];
    const callbackRows = this.database
      .prepare(
        `SELECT record_json FROM runtime_callback_events
         WHERE runtime_run_id IN (SELECT runtime_run_id FROM runtime_runs WHERE task_id = ?)
         ORDER BY occurred_at, callback_event_id`,
      )
      .all(taskId) as Array<{ record_json: string }>;
    return {
      task,
      runtimeRuns: runRows.map(runtimeRunRecord),
      callbacks: callbackRows.map((row) => JSON.parse(row.record_json) as RuntimeCallback),
    };
  }

  private getRuntimeRunRow(runtimeRunId: string): RuntimeRunRow | undefined {
    return this.database
      .prepare("SELECT * FROM runtime_runs WHERE runtime_run_id = ?")
      .get(runtimeRunId) as RuntimeRunRow | undefined;
  }

  getDecision(decisionId: string): AttentionEvaluation | undefined {
    const row = this.database
      .prepare("SELECT record_json FROM decisions WHERE decision_id = ?")
      .get(decisionId) as { record_json: string } | undefined;
    return row ? (JSON.parse(row.record_json) as AttentionEvaluation) : undefined;
  }

  listEpisodes(): Array<{ episode: EpisodeProjection; latestDecision?: AttentionEvaluation }> {
    const rows = this.database
      .prepare("SELECT state_json FROM episodes ORDER BY updated_at DESC, episode_id")
      .all() as Array<{ state_json: string }>;
    return rows.map((row) => {
      const episode = JSON.parse(row.state_json) as EpisodeProjection;
      const decisionRow = this.database
        .prepare(
          `SELECT record_json FROM decisions WHERE episode_id = ?
           ORDER BY created_at DESC, decision_id DESC LIMIT 1`,
        )
        .get(episode.episodeId) as { record_json: string } | undefined;
      return {
        episode,
        ...(decisionRow
          ? { latestDecision: JSON.parse(decisionRow.record_json) as AttentionEvaluation }
          : {}),
      };
    });
  }

  getEpisodeTimeline(episodeId: string):
    | {
        episode: EpisodeProjection;
        cues: CueEvent[];
        decisions: AttentionEvaluation[];
      }
    | undefined {
    const episode = this.getEpisode(episodeId);
    if (!episode) return undefined;
    const decisionRows = this.database
      .prepare(
        `SELECT record_json FROM decisions WHERE episode_id = ?
         ORDER BY created_at, decision_id`,
      )
      .all(episodeId) as Array<{ record_json: string }>;
    return {
      episode,
      cues: this.getEvents(episode.eventIds),
      decisions: decisionRows.map((row) => JSON.parse(row.record_json) as AttentionEvaluation),
    };
  }

  getEpisode(episodeId: string): EpisodeProjection | undefined {
    const row = this.database
      .prepare("SELECT state_json FROM episodes WHERE episode_id = ?")
      .get(episodeId) as { state_json: string } | undefined;
    return row ? (JSON.parse(row.state_json) as EpisodeProjection) : undefined;
  }

  replay(eventIds?: readonly string[]) {
    return replayCueEvents(this.getEvents(eventIds));
  }
}
