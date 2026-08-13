ALTER TABLE tool_attempts ADD COLUMN agent_run_id TEXT;
ALTER TABLE tool_attempts ADD COLUMN tool_call_id TEXT;
ALTER TABLE tool_attempts ADD COLUMN policy_decision TEXT;
ALTER TABLE tool_attempts ADD COLUMN reason_code TEXT;
ALTER TABLE tool_attempts ADD COLUMN updated_at TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_tool_attempt_logical_call
ON tool_attempts(runtime_run_id, agent_run_id, tool_call_id);

CREATE INDEX IF NOT EXISTS idx_tool_attempt_status_created
ON tool_attempts(status, created_at);

CREATE TABLE IF NOT EXISTS tool_attempt_events (
  attempt_event_id TEXT PRIMARY KEY,
  attempt_id TEXT NOT NULL REFERENCES tool_attempts(attempt_id),
  event_type TEXT NOT NULL,
  payload_digest TEXT NOT NULL,
  record_json TEXT NOT NULL,
  occurred_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS permit_events (
  permit_event_id TEXT PRIMARY KEY,
  permit_id TEXT NOT NULL REFERENCES permits(permit_id),
  attempt_id TEXT NOT NULL REFERENCES tool_attempts(attempt_id),
  event_type TEXT NOT NULL,
  payload_digest TEXT NOT NULL,
  record_json TEXT NOT NULL,
  occurred_at TEXT NOT NULL
);

CREATE TRIGGER IF NOT EXISTS tool_attempt_events_append_only_update
BEFORE UPDATE ON tool_attempt_events
BEGIN
  SELECT RAISE(ABORT, 'tool attempt events are append-only');
END;

CREATE TRIGGER IF NOT EXISTS tool_attempt_events_append_only_delete
BEFORE DELETE ON tool_attempt_events
BEGIN
  SELECT RAISE(ABORT, 'tool attempt events are append-only');
END;

CREATE TRIGGER IF NOT EXISTS permit_events_append_only_update
BEFORE UPDATE ON permit_events
BEGIN
  SELECT RAISE(ABORT, 'permit events are append-only');
END;

CREATE TRIGGER IF NOT EXISTS permit_events_append_only_delete
BEFORE DELETE ON permit_events
BEGIN
  SELECT RAISE(ABORT, 'permit events are append-only');
END;

CREATE INDEX IF NOT EXISTS idx_tool_attempt_events_attempt
ON tool_attempt_events(attempt_id, occurred_at);

CREATE INDEX IF NOT EXISTS idx_permit_events_permit
ON permit_events(permit_id, occurred_at);
