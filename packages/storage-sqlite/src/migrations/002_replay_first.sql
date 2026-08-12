ALTER TABLE events ADD COLUMN payload_hash TEXT;

UPDATE events SET payload_hash = '' WHERE payload_hash IS NULL;

CREATE TABLE IF NOT EXISTS ingress_errors (
  error_id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL,
  body_digest TEXT NOT NULL,
  idempotency_key TEXT,
  reason_code TEXT NOT NULL,
  details_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TRIGGER IF NOT EXISTS events_append_only_update
BEFORE UPDATE ON events
BEGIN
  SELECT RAISE(ABORT, 'events are append-only');
END;

CREATE TRIGGER IF NOT EXISTS events_append_only_delete
BEFORE DELETE ON events
BEGIN
  SELECT RAISE(ABORT, 'events are append-only');
END;

CREATE INDEX IF NOT EXISTS idx_ingress_errors_source_created
ON ingress_errors(source_id, created_at);
