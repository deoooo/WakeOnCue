CREATE TABLE IF NOT EXISTS runtime_callback_events (
  callback_event_id TEXT PRIMARY KEY,
  runtime_run_id TEXT NOT NULL REFERENCES runtime_runs(runtime_run_id),
  agent_run_id TEXT NOT NULL,
  status TEXT NOT NULL,
  payload_digest TEXT NOT NULL,
  record_json TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  received_at TEXT NOT NULL,
  UNIQUE(runtime_run_id, payload_digest)
);

CREATE TRIGGER IF NOT EXISTS runtime_callback_events_append_only_update
BEFORE UPDATE ON runtime_callback_events
BEGIN
  SELECT RAISE(ABORT, 'runtime callback events are append-only');
END;

CREATE TRIGGER IF NOT EXISTS runtime_callback_events_append_only_delete
BEFORE DELETE ON runtime_callback_events
BEGIN
  SELECT RAISE(ABORT, 'runtime callback events are append-only');
END;

CREATE INDEX IF NOT EXISTS idx_runtime_callbacks_run_occurred
ON runtime_callback_events(runtime_run_id, occurred_at);

CREATE INDEX IF NOT EXISTS idx_runtime_runs_status
ON runtime_runs(status, last_observed_at);
