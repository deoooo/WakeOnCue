import Database from "better-sqlite3";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import type { CueEvent } from "@wakeoncue/contracts";
import { canonicalJson, replayCueEvents, sha256, type EpisodeProjection } from "@wakeoncue/core";
import type { AppendEventResult, EventStore, IngressErrorRecord } from "@wakeoncue/storage";

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

function idempotencyPayloadHash(event: CueEvent): string {
  return sha256(canonicalJson({ ...event, receivedAt: "<ingress-received-at>" }));
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
        this.database
          .prepare("UPDATE outbox SET status = 'COMPLETED', completed_at = ? WHERE outbox_id = ?")
          .run(now, row.outbox_id);
      })();
    }
    return rows.length;
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
