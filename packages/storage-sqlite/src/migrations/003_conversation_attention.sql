ALTER TABLE decisions ADD COLUMN subject TEXT;
ALTER TABLE decisions ADD COLUMN source_id TEXT;
ALTER TABLE decisions ADD COLUMN cue_type TEXT;
ALTER TABLE decisions ADD COLUMN mode TEXT;
ALTER TABLE decisions ADD COLUMN disposition TEXT;
ALTER TABLE decisions ADD COLUMN cooldown_key TEXT;
ALTER TABLE decisions ADD COLUMN expires_at TEXT;
ALTER TABLE decisions ADD COLUMN episode_version INTEGER;

CREATE TABLE IF NOT EXISTS attention_daily_usage (
  subject TEXT NOT NULL,
  usage_date TEXT NOT NULL,
  wake_count INTEGER NOT NULL DEFAULT 0,
  notification_count INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (subject, usage_date)
);

CREATE TABLE IF NOT EXISTS source_gate_evidence (
  source_id TEXT NOT NULL,
  cue_type TEXT NOT NULL,
  evidence_json TEXT NOT NULL,
  calculated_at TEXT NOT NULL,
  PRIMARY KEY (source_id, cue_type)
);

CREATE INDEX IF NOT EXISTS idx_decisions_subject_cooldown
ON decisions(subject, cooldown_key, expires_at);

CREATE INDEX IF NOT EXISTS idx_decisions_episode_created
ON decisions(episode_id, created_at);
