CREATE TABLE IF NOT EXISTS privacy_deletion_context (
  context_id INTEGER PRIMARY KEY CHECK (context_id = 1),
  active INTEGER NOT NULL CHECK (active = 1)
);

CREATE TABLE IF NOT EXISTS privacy_tombstones (
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  tombstoned_at TEXT NOT NULL,
  PRIMARY KEY(entity_type, entity_id)
);

CREATE TABLE IF NOT EXISTS privacy_deletion_requests (
  deletion_id TEXT PRIMARY KEY,
  idempotency_key TEXT NOT NULL UNIQUE,
  subject_digest TEXT NOT NULL,
  counts_json TEXT NOT NULL,
  requested_at TEXT NOT NULL,
  completed_at TEXT NOT NULL
);

DROP TRIGGER IF EXISTS events_append_only_update;
CREATE TRIGGER events_append_only_update
BEFORE UPDATE ON events
WHEN NOT EXISTS (SELECT 1 FROM privacy_deletion_context WHERE context_id = 1 AND active = 1)
BEGIN SELECT RAISE(ABORT, 'events are append-only'); END;

DROP TRIGGER IF EXISTS runtime_callback_events_append_only_update;
CREATE TRIGGER runtime_callback_events_append_only_update
BEFORE UPDATE ON runtime_callback_events
WHEN NOT EXISTS (SELECT 1 FROM privacy_deletion_context WHERE context_id = 1 AND active = 1)
BEGIN SELECT RAISE(ABORT, 'runtime callback events are append-only'); END;

DROP TRIGGER IF EXISTS tool_attempt_events_append_only_update;
CREATE TRIGGER tool_attempt_events_append_only_update
BEFORE UPDATE ON tool_attempt_events
WHEN NOT EXISTS (SELECT 1 FROM privacy_deletion_context WHERE context_id = 1 AND active = 1)
BEGIN SELECT RAISE(ABORT, 'tool attempt events are append-only'); END;

DROP TRIGGER IF EXISTS permit_events_append_only_update;
CREATE TRIGGER permit_events_append_only_update
BEFORE UPDATE ON permit_events
WHEN NOT EXISTS (SELECT 1 FROM privacy_deletion_context WHERE context_id = 1 AND active = 1)
BEGIN SELECT RAISE(ABORT, 'permit events are append-only'); END;

DROP TRIGGER IF EXISTS outcomes_append_only_update;
CREATE TRIGGER outcomes_append_only_update
BEFORE UPDATE ON outcomes
WHEN NOT EXISTS (SELECT 1 FROM privacy_deletion_context WHERE context_id = 1 AND active = 1)
BEGIN SELECT RAISE(ABORT, 'outcomes are append-only'); END;

DROP TRIGGER IF EXISTS outcome_events_append_only_update;
CREATE TRIGGER outcome_events_append_only_update
BEFORE UPDATE ON outcome_events
WHEN NOT EXISTS (SELECT 1 FROM privacy_deletion_context WHERE context_id = 1 AND active = 1)
BEGIN SELECT RAISE(ABORT, 'outcome events are append-only'); END;

DROP TRIGGER IF EXISTS native_notification_receipts_append_only_update;
CREATE TRIGGER native_notification_receipts_append_only_update
BEFORE UPDATE ON native_notification_receipts
WHEN NOT EXISTS (SELECT 1 FROM privacy_deletion_context WHERE context_id = 1 AND active = 1)
BEGIN SELECT RAISE(ABORT, 'native notification receipts are append-only'); END;

DROP TRIGGER IF EXISTS notification_receipt_events_append_only_update;
CREATE TRIGGER notification_receipt_events_append_only_update
BEFORE UPDATE ON notification_receipt_events
WHEN NOT EXISTS (SELECT 1 FROM privacy_deletion_context WHERE context_id = 1 AND active = 1)
BEGIN SELECT RAISE(ABORT, 'notification receipt events are append-only'); END;

CREATE TRIGGER IF NOT EXISTS privacy_deletion_requests_append_only_update
BEFORE UPDATE ON privacy_deletion_requests
BEGIN SELECT RAISE(ABORT, 'privacy deletion requests are append-only'); END;

CREATE TRIGGER IF NOT EXISTS privacy_deletion_requests_append_only_delete
BEFORE DELETE ON privacy_deletion_requests
BEGIN SELECT RAISE(ABORT, 'privacy deletion requests are append-only'); END;
