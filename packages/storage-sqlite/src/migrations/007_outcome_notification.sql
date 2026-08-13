ALTER TABLE notifications ADD COLUMN updated_at TEXT;
ALTER TABLE feedback ADD COLUMN idempotency_key TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_feedback_idempotency
ON feedback(idempotency_key) WHERE idempotency_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS outcome_events (
  outcome_event_id TEXT PRIMARY KEY,
  outcome_id TEXT NOT NULL REFERENCES outcomes(outcome_id),
  task_id TEXT NOT NULL REFERENCES tasks(task_id),
  runtime_run_id TEXT NOT NULL REFERENCES runtime_runs(runtime_run_id),
  verification TEXT NOT NULL,
  payload_digest TEXT NOT NULL,
  record_json TEXT NOT NULL,
  occurred_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS native_notification_receipts (
  receipt_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL REFERENCES tasks(task_id),
  outcome_id TEXT NOT NULL REFERENCES outcomes(outcome_id),
  runtime_run_id TEXT NOT NULL REFERENCES runtime_runs(runtime_run_id),
  channel TEXT NOT NULL,
  status TEXT NOT NULL,
  record_json TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  UNIQUE(outcome_id, channel)
);

CREATE TABLE IF NOT EXISTS notification_receipt_events (
  receipt_event_id TEXT PRIMARY KEY,
  notification_id TEXT NOT NULL REFERENCES notifications(notification_id),
  status TEXT NOT NULL,
  payload_digest TEXT NOT NULL,
  record_json TEXT NOT NULL,
  occurred_at TEXT NOT NULL
);

CREATE TRIGGER IF NOT EXISTS outcomes_append_only_update
BEFORE UPDATE ON outcomes
BEGIN
  SELECT RAISE(ABORT, 'outcomes are append-only');
END;

CREATE TRIGGER IF NOT EXISTS outcomes_append_only_delete
BEFORE DELETE ON outcomes
BEGIN
  SELECT RAISE(ABORT, 'outcomes are append-only');
END;

CREATE TRIGGER IF NOT EXISTS outcome_events_append_only_update
BEFORE UPDATE ON outcome_events
BEGIN
  SELECT RAISE(ABORT, 'outcome events are append-only');
END;

CREATE TRIGGER IF NOT EXISTS outcome_events_append_only_delete
BEFORE DELETE ON outcome_events
BEGIN
  SELECT RAISE(ABORT, 'outcome events are append-only');
END;

CREATE TRIGGER IF NOT EXISTS native_notification_receipts_append_only_update
BEFORE UPDATE ON native_notification_receipts
BEGIN
  SELECT RAISE(ABORT, 'native notification receipts are append-only');
END;

CREATE TRIGGER IF NOT EXISTS native_notification_receipts_append_only_delete
BEFORE DELETE ON native_notification_receipts
BEGIN
  SELECT RAISE(ABORT, 'native notification receipts are append-only');
END;

CREATE TRIGGER IF NOT EXISTS notification_receipt_events_append_only_update
BEFORE UPDATE ON notification_receipt_events
BEGIN
  SELECT RAISE(ABORT, 'notification receipt events are append-only');
END;

CREATE TRIGGER IF NOT EXISTS notification_receipt_events_append_only_delete
BEFORE DELETE ON notification_receipt_events
BEGIN
  SELECT RAISE(ABORT, 'notification receipt events are append-only');
END;

CREATE INDEX IF NOT EXISTS idx_outcomes_task_created
ON outcomes(task_id, created_at);

CREATE INDEX IF NOT EXISTS idx_outcome_events_task_occurred
ON outcome_events(task_id, occurred_at);

CREATE INDEX IF NOT EXISTS idx_notifications_status_created
ON notifications(status, created_at);
