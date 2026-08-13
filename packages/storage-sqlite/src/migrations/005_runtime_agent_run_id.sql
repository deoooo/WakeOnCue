ALTER TABLE runtime_runs ADD COLUMN agent_run_id TEXT;

CREATE INDEX IF NOT EXISTS idx_runtime_runs_agent_run
ON runtime_runs(agent_run_id);
