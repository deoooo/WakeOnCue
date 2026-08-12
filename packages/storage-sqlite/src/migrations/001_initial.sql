PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS events (
  event_id TEXT PRIMARY KEY,
  spec_version TEXT NOT NULL,
  event_type TEXT NOT NULL,
  subject TEXT NOT NULL,
  source_adapter TEXT NOT NULL,
  source_id TEXT NOT NULL,
  correlation_id TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  received_at TEXT NOT NULL,
  idempotency_key TEXT NOT NULL UNIQUE,
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS event_payloads (
  event_id TEXT PRIMARY KEY REFERENCES events(event_id),
  encrypted_payload BLOB,
  evidence_refs_json TEXT NOT NULL,
  tombstoned_at TEXT
);

CREATE TABLE IF NOT EXISTS episodes (
  episode_id TEXT PRIMARY KEY,
  subject TEXT NOT NULL,
  correlation_key TEXT NOT NULL,
  state_json TEXT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS entities (
  entity_id TEXT PRIMARY KEY,
  episode_id TEXT NOT NULL REFERENCES episodes(episode_id),
  entity_type TEXT NOT NULL,
  value_json TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS decisions (
  decision_id TEXT PRIMARY KEY,
  episode_id TEXT NOT NULL REFERENCES episodes(episode_id),
  decision TEXT NOT NULL,
  reason_codes_json TEXT NOT NULL,
  evidence_refs_json TEXT NOT NULL,
  strategy_version TEXT NOT NULL,
  model_ref TEXT,
  record_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS observation_requests (
  observation_id TEXT PRIMARY KEY,
  episode_id TEXT NOT NULL REFERENCES episodes(episode_id),
  capability TEXT NOT NULL,
  purpose TEXT NOT NULL,
  scope_json TEXT NOT NULL,
  budget_json TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  status TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tasks (
  task_id TEXT PRIMARY KEY,
  decision_id TEXT NOT NULL REFERENCES decisions(decision_id),
  idempotency_key TEXT NOT NULL UNIQUE,
  contract_json TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS runtime_runs (
  runtime_run_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL REFERENCES tasks(task_id),
  adapter TEXT NOT NULL,
  external_run_id TEXT,
  idempotency_key TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL,
  last_observed_at TEXT,
  record_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tool_attempts (
  attempt_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL REFERENCES tasks(task_id),
  runtime_run_id TEXT NOT NULL REFERENCES runtime_runs(runtime_run_id),
  tool TEXT NOT NULL,
  arguments_digest TEXT NOT NULL,
  record_json TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS permits (
  permit_id TEXT PRIMARY KEY,
  attempt_id TEXT NOT NULL UNIQUE REFERENCES tool_attempts(attempt_id),
  subject TEXT NOT NULL,
  runtime_run_id TEXT NOT NULL,
  task_id TEXT NOT NULL,
  tool TEXT NOT NULL,
  arguments_digest TEXT NOT NULL,
  issued_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  consumed_at TEXT
);

CREATE TABLE IF NOT EXISTS outcomes (
  outcome_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL REFERENCES tasks(task_id),
  runtime_run_id TEXT NOT NULL REFERENCES runtime_runs(runtime_run_id),
  idempotency_key TEXT NOT NULL UNIQUE,
  verification TEXT NOT NULL,
  record_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS notifications (
  notification_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL REFERENCES tasks(task_id),
  outcome_id TEXT REFERENCES outcomes(outcome_id),
  channel TEXT NOT NULL,
  deduplication_key TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL,
  record_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS feedback (
  feedback_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL REFERENCES tasks(task_id),
  kind TEXT NOT NULL,
  record_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS outbox (
  outbox_id TEXT PRIMARY KEY,
  topic TEXT NOT NULL,
  aggregate_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL UNIQUE,
  payload_json TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'PENDING',
  attempt_count INTEGER NOT NULL DEFAULT 0,
  available_at TEXT NOT NULL,
  claimed_at TEXT,
  completed_at TEXT,
  last_error TEXT
);

CREATE TABLE IF NOT EXISTS deliveries (
  delivery_id TEXT PRIMARY KEY,
  consumer TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  external_ref TEXT,
  status TEXT NOT NULL,
  record_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (consumer, idempotency_key)
);

CREATE TABLE IF NOT EXISTS source_modes (
  source_id TEXT NOT NULL,
  cue_type TEXT NOT NULL,
  mode TEXT NOT NULL CHECK (mode IN ('SHADOW', 'NOTIFY', 'WAKE')),
  gate_evidence_json TEXT NOT NULL DEFAULT '{}',
  updated_at TEXT NOT NULL,
  PRIMARY KEY (source_id, cue_type)
);

CREATE INDEX IF NOT EXISTS idx_events_correlation ON events(subject, correlation_id, occurred_at);
CREATE INDEX IF NOT EXISTS idx_outbox_ready ON outbox(status, available_at);
CREATE INDEX IF NOT EXISTS idx_runtime_runs_task ON runtime_runs(task_id);
