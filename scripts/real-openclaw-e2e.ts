import { randomBytes } from "node:crypto";
import { spawn, type ChildProcess } from "node:child_process";
import { createWriteStream } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { basename, join, resolve } from "node:path";

import type { TaskContract } from "@wakeoncue/contracts";
import { OpenClawRuntimeAdapter } from "@wakeoncue/runtime-openclaw";
import { migrateDatabase, openDatabase, SqliteWakeStore } from "@wakeoncue/storage-sqlite";

const root = resolve(import.meta.dirname, "..");
const openClawBin = process.env["WAKEONCUE_OPENCLAW_BIN"];
const openClawNodeBinDir = process.env["WAKEONCUE_OPENCLAW_NODE_BIN_DIR"];
if (!openClawBin || !openClawNodeBinDir) {
  throw new Error(
    "Set WAKEONCUE_OPENCLAW_BIN and WAKEONCUE_OPENCLAW_NODE_BIN_DIR to the fixed OpenClaw CLI and Node 24 bin directory",
  );
}

const startedAt = new Date();
const runLabel = startedAt.toISOString().replaceAll(/[:.]/gu, "-");
const runDir = join(root, ".runtime", "real-openclaw-e2e", runLabel);
const openClawRuntimeDir = join(root, ".runtime", "openclaw-e2e");
const stateDir = join(openClawRuntimeDir, "state");
const configPath = join(stateDir, "openclaw.json");
const databasePath = join(runDir, "wakeoncue.sqlite");
const artifactPath = join(runDir, "result.json");
await mkdir(runDir, { recursive: true, mode: 0o700 });

const gatewayToken = randomBytes(32).toString("hex");
const hookToken = randomBytes(32).toString("hex");
const callbackSecret = randomBytes(32).toString("hex");
const pepSecret = randomBytes(32).toString("hex");
const omiToken = randomBytes(32).toString("hex");
const managed: Array<{ label: string; child: ChildProcess }> = [];

async function freePort(): Promise<number> {
  return new Promise((resolvePort, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        reject(new Error("Could not allocate a local TCP port"));
        return;
      }
      server.close((error) => (error ? reject(error) : resolvePort(address.port)));
    });
  });
}

async function runCommand(
  command: string,
  args: string[],
  env: NodeJS.ProcessEnv,
  input?: string,
): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolveCommand, reject) => {
    const child = spawn(command, args, { cwd: root, env, stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.once("error", reject);
    child.once("exit", (code) => {
      if (code === 0) resolveCommand({ stdout, stderr });
      else reject(new Error(`${basename(command)} exited ${code}: ${stderr || stdout}`));
    });
    child.stdin.end(input ?? "");
  });
}

function startManaged(
  label: string,
  command: string,
  args: string[],
  env: NodeJS.ProcessEnv,
): ChildProcess {
  const logPath = join(runDir, `${label}.log`);
  const output = createWriteStream(logPath, { flags: "a", mode: 0o600 });
  const child = spawn(command, args, { cwd: root, env, stdio: ["ignore", "pipe", "pipe"] });
  child.stdout?.pipe(output, { end: false });
  child.stderr?.pipe(output, { end: false });
  child.once("exit", (code, signal) => {
    output.write(`\n[process-exit] code=${String(code)} signal=${String(signal)}\n`);
    output.end();
  });
  managed.push({ label, child });
  return child;
}

async function waitFor<T>(
  description: string,
  probe: () => Promise<T | undefined> | T | undefined,
  timeoutMs: number,
): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  let lastError: unknown;
  while (Date.now() < deadline) {
    try {
      const value = await probe();
      if (value !== undefined) return value;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolveWait) => setTimeout(resolveWait, 500));
  }
  throw new Error(
    `${description} did not become ready within ${timeoutMs}ms${
      lastError instanceof Error ? `: ${lastError.message}` : ""
    }`,
  );
}

async function stopManaged(): Promise<void> {
  for (const { child } of managed.toReversed()) {
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
  }
  await new Promise((resolveWait) => setTimeout(resolveWait, 1_000));
  for (const { child } of managed.toReversed()) {
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
  }
}

function queryRuntime():
  | {
      taskId: string;
      contract: TaskContract;
      taskStatus: string;
      runtimeRunId: string;
      externalRunId?: string;
      agentRunId?: string;
      runtimeStatus: string;
    }
  | undefined {
  const database = openDatabase(databasePath);
  try {
    const row = database
      .prepare(
        `SELECT t.task_id, t.contract_json, t.status AS task_status,
                r.runtime_run_id, r.external_run_id, r.agent_run_id, r.status AS runtime_status
         FROM tasks t JOIN runtime_runs r USING(task_id)
         ORDER BY t.created_at DESC LIMIT 1`,
      )
      .get() as
      | {
          task_id: string;
          contract_json: string;
          task_status: string;
          runtime_run_id: string;
          external_run_id: string | null;
          agent_run_id: string | null;
          runtime_status: string;
        }
      | undefined;
    return row
      ? {
          taskId: row.task_id,
          contract: JSON.parse(row.contract_json) as TaskContract,
          taskStatus: row.task_status,
          runtimeRunId: row.runtime_run_id,
          ...(row.external_run_id ? { externalRunId: row.external_run_id } : {}),
          ...(row.agent_run_id ? { agentRunId: row.agent_run_id } : {}),
          runtimeStatus: row.runtime_status,
        }
      : undefined;
  } finally {
    database.close();
  }
}

let artifact: Record<string, unknown> = {
  specVersion: "wakeoncue.evidence.real-openclaw/v1",
  status: "FAIL",
  startedAt: startedAt.toISOString(),
  boundaries: {
    input: "versioned de-identified Omi fixture",
    runtime: "real OpenClaw process and real configured model provider",
    productionCanary: false,
    liveWakeGate: "controlled temporary E2E database only",
  },
};

try {
  const [gatewayPort, apiPort] = await Promise.all([freePort(), freePort()]);
  const commonOpenClawEnv: NodeJS.ProcessEnv = {
    ...process.env,
    PATH: `${openClawNodeBinDir}:${process.env["PATH"] ?? ""}`,
    OPENCLAW_STATE_DIR: stateDir,
    OPENCLAW_CONFIG_PATH: configPath,
    OPENCLAW_GATEWAY_TOKEN: gatewayToken,
    OPENCLAW_HOOK_TOKEN: hookToken,
    OPENCLAW_SKIP_CHANNELS: "1",
  };

  await runCommand(process.execPath, ["scripts/prepare-openclaw-runtime.mjs"], {
    ...commonOpenClawEnv,
    WAKEONCUE_OPENCLAW_RUNTIME_DIR: openClawRuntimeDir,
    WAKEONCUE_OPENCLAW_PORT: String(gatewayPort),
    WAKEONCUE_OPENCLAW_COPY_AUTH: "1",
  });
  await runCommand(process.execPath, ["scripts/import-openclaw-auth.mjs"], {
    ...commonOpenClawEnv,
    WAKEONCUE_OPENCLAW_RUNTIME_DIR: openClawRuntimeDir,
    WAKEONCUE_OPENCLAW_IMPORT_AUTH: "1",
    WAKEONCUE_OPENCLAW_BIN: openClawBin,
    WAKEONCUE_OPENCLAW_NODE_BIN_DIR: openClawNodeBinDir,
  });

  const database = openDatabase(databasePath);
  migrateDatabase(database);
  const store = new SqliteWakeStore(database);
  store.recordSourceGateEvidence("omi-real-openclaw-e2e", "conversation.finalized", {
    shadowDays: 7,
    explicitCommitmentPrecision: 0.95,
    falseWakeRatePerUserDay: 0.1,
    privacyViolationCount: 0,
    evidenceRef: "fixture://controlled-real-openclaw-e2e",
    userExplicitlyEnabled: true,
    runtimeIdempotencyPassed: true,
    pepConformancePassed: true,
    authorizationAttackSuitePassed: true,
    sourcePauseAvailable: true,
  });
  store.setSourceMode("omi-real-openclaw-e2e", "conversation.finalized", "WAKE");
  database.close();

  const callbackUrl = `http://127.0.0.1:${apiPort}/v1/runtime/callbacks/openclaw`;
  const gateway = startManaged(
    "openclaw",
    openClawBin,
    [
      "gateway",
      "run",
      "--port",
      String(gatewayPort),
      "--bind",
      "loopback",
      "--token",
      gatewayToken,
      "--compact",
    ],
    {
      ...commonOpenClawEnv,
      WAKEONCUE_RUNTIME_CALLBACK_SECRET: callbackSecret,
      WAKEONCUE_RUNTIME_PEP_SECRET: pepSecret,
      WAKEONCUE_RUNTIME_CALLBACK_URL: callbackUrl,
    },
  );
  const api = startManaged("api", process.execPath, ["--import", "tsx", "apps/api/src/main.ts"], {
    ...process.env,
    WAKEONCUE_DATABASE_PATH: databasePath,
    WAKEONCUE_API_PORT: String(apiPort),
    WAKEONCUE_OMI_WEBHOOK_TOKEN: omiToken,
    WAKEONCUE_OMI_SUBJECT: "subject-controlled-real-openclaw-e2e",
    WAKEONCUE_RUNTIME_CALLBACK_SECRET: callbackSecret,
    WAKEONCUE_RUNTIME_PEP_SECRET: pepSecret,
    WAKEONCUE_LOG_LEVEL: "info",
  });

  const health = await waitFor(
    "OpenClaw health",
    async () => {
      if (gateway.exitCode !== null) throw new Error(`OpenClaw exited ${gateway.exitCode}`);
      const response = await fetch(`http://127.0.0.1:${gatewayPort}/health`);
      if (!response.ok) return undefined;
      const value = (await response.json()) as Record<string, unknown>;
      return value["ok"] === true ? value : undefined;
    },
    60_000,
  );
  await waitFor(
    "wakeoncue-guard plugin",
    async () => {
      const gatewayLog = await readFile(join(runDir, "openclaw.log"), "utf8");
      return gatewayLog.includes("1 plugin: wakeoncue-guard") ? true : undefined;
    },
    60_000,
  );
  await waitFor(
    "WakeOnCue API",
    async () => {
      if (api.exitCode !== null) throw new Error(`API exited ${api.exitCode}`);
      const response = await fetch(`http://127.0.0.1:${apiPort}/ready`);
      return response.ok ? true : undefined;
    },
    30_000,
  );

  const worker = startManaged(
    "worker",
    process.execPath,
    ["--import", "tsx", "apps/worker/src/main.ts"],
    {
      ...process.env,
      WAKEONCUE_DATABASE_PATH: databasePath,
      WAKEONCUE_RUNTIME_ADAPTER: "openclaw",
      WAKEONCUE_OPENCLAW_BASE_URL: `http://127.0.0.1:${gatewayPort}`,
      WAKEONCUE_OPENCLAW_HOOK_TOKEN: hookToken,
      WAKEONCUE_OPENCLAW_PLUGIN_VERIFIED: "1",
      WAKEONCUE_OPENCLAW_MODEL: "modelstudio/glm-5",
      WAKEONCUE_OPENCLAW_AGENT_TIMEOUT_SECONDS: "180",
      WAKEONCUE_RUNTIME_CALLBACK_URL: callbackUrl,
      WAKEONCUE_QUIET_START_HOUR: "0",
      WAKEONCUE_QUIET_END_HOUR: "0",
    },
  );
  await new Promise((resolveWait) => setTimeout(resolveWait, 1_000));
  if (worker.exitCode !== null) throw new Error(`Worker exited ${worker.exitCode}`);

  const fixture = JSON.parse(
    await readFile(
      join(root, "packages/source-omi/fixtures/finalized-conversation.v1.json"),
      "utf8",
    ),
  ) as Record<string, unknown>;
  fixture["id"] = `conversation_real_openclaw_${runLabel}`;
  const fixtureBody = JSON.stringify(fixture);
  const ingest = await fetch(`http://127.0.0.1:${apiPort}/v1/sources/omi/omi-real-openclaw-e2e`, {
    method: "POST",
    headers: { authorization: `Bearer ${omiToken}`, "content-type": "application/json" },
    body: fixtureBody,
  });
  if (ingest.status !== 202)
    throw new Error(`Omi fixture ingestion returned HTTP ${ingest.status}`);
  const ingestBody = (await ingest.json()) as {
    event: { eventId: string };
    inserted: boolean;
  };

  const runtime = await waitFor(
    "real OpenClaw terminal callback",
    () => {
      const value = queryRuntime();
      if (!value) return undefined;
      if (["FAILED", "CANCELLED", "UNKNOWN"].includes(value.runtimeStatus)) {
        throw new Error(`Real OpenClaw run ended ${value.runtimeStatus}`);
      }
      return value.runtimeStatus === "SUCCEEDED" ? value : undefined;
    },
    240_000,
  );
  if (!runtime.externalRunId || !runtime.agentRunId) {
    throw new Error("Real OpenClaw run did not return both activation and agent-turn IDs");
  }

  const callbackDatabase = openDatabase(databasePath);
  const callbackRows = callbackDatabase
    .prepare(
      `SELECT status, agent_run_id FROM runtime_callback_events
       WHERE runtime_run_id = ? ORDER BY occurred_at`,
    )
    .all(runtime.runtimeRunId) as Array<{ status: string; agent_run_id: string }>;
  const taskCountBeforeReplay = (
    callbackDatabase.prepare("SELECT COUNT(*) AS count FROM tasks").get() as { count: number }
  ).count;
  callbackDatabase.close();
  if (callbackRows.map((row) => row.status).join(",") !== "RUNNING,SUCCEEDED") {
    throw new Error(
      `Unexpected callback lifecycle: ${callbackRows.map((row) => row.status).join(",")}`,
    );
  }

  const replayed = await fetch(`http://127.0.0.1:${apiPort}/v1/sources/omi/omi-real-openclaw-e2e`, {
    method: "POST",
    headers: { authorization: `Bearer ${omiToken}`, "content-type": "application/json" },
    body: fixtureBody,
  });
  const replayedBody = (await replayed.json()) as { inserted: boolean; status: string };
  if (replayed.status !== 200 || replayedBody.inserted || replayedBody.status !== "duplicate") {
    throw new Error("Duplicate Omi fixture was not deduplicated");
  }

  const adapter = new OpenClawRuntimeAdapter({
    baseUrl: `http://127.0.0.1:${gatewayPort}`,
    hookToken,
    agentId: "main",
    model: "modelstudio/glm-5",
    pluginVerified: true,
    agentTimeoutSeconds: 180,
  });
  const duplicateReceipt = await adapter.activate(runtime.contract, {
    runtimeRunId: runtime.runtimeRunId,
    idempotencyKey: runtime.contract.idempotencyKey,
    callbackUrl,
  });
  if (duplicateReceipt.externalRunId !== runtime.externalRunId) {
    throw new Error("OpenClaw returned a different run ID for the same activation idempotency key");
  }
  await new Promise((resolveWait) => setTimeout(resolveWait, 1_500));

  const replayDatabase = openDatabase(databasePath);
  const taskCountAfterReplay = (
    replayDatabase.prepare("SELECT COUNT(*) AS count FROM tasks").get() as { count: number }
  ).count;
  const callbackCountAfterReplay = (
    replayDatabase
      .prepare("SELECT COUNT(*) AS count FROM runtime_callback_events WHERE runtime_run_id = ?")
      .get(runtime.runtimeRunId) as { count: number }
  ).count;
  const toolAttemptRows = replayDatabase
    .prepare(
      `SELECT tool, status, policy_decision, reason_code, record_json
       FROM tool_attempts WHERE runtime_run_id = ? ORDER BY created_at`,
    )
    .all(runtime.runtimeRunId) as Array<{
    tool: string;
    status: string;
    policy_decision: string;
    reason_code: string;
    record_json: string;
  }>;
  const unauthorizedSensitiveExecutions = (
    replayDatabase
      .prepare(
        `SELECT COUNT(*) AS count
         FROM tool_attempts a
         WHERE a.runtime_run_id = ?
           AND json_extract(a.record_json, '$.risk.sideEffect') != 'none'
           AND a.status IN ('EXECUTING', 'SUCCEEDED')
           AND NOT EXISTS (
             SELECT 1 FROM permits p
             WHERE p.attempt_id = a.attempt_id AND p.consumed_at IS NOT NULL
           )`,
      )
      .get(runtime.runtimeRunId) as { count: number }
  ).count;
  replayDatabase.close();
  if (taskCountBeforeReplay !== 1 || taskCountAfterReplay !== 1 || callbackCountAfterReplay !== 2) {
    throw new Error("Replay produced a duplicate Task or runtime callback");
  }

  const sessionPath = join(stateDir, "agents", "main", "sessions", `${runtime.agentRunId}.jsonl`);
  const sessionLines = (await readFile(sessionPath, "utf8"))
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line) as Record<string, unknown>);
  let agentSelectedToolCalls = 0;
  let pepBlockedToolCalls = 0;
  for (const line of sessionLines) {
    const message = line["message"] as Record<string, unknown> | undefined;
    const content = message?.["content"];
    if (message?.["role"] === "assistant" && Array.isArray(content)) {
      agentSelectedToolCalls += (content as unknown[]).filter((part) => {
        const record =
          typeof part === "object" && part !== null ? (part as Record<string, unknown>) : undefined;
        return record?.["type"] === "toolCall";
      }).length;
    }
    if (
      message?.["role"] === "toolResult" &&
      JSON.stringify(message).includes("WAKEONCUE_DENIED:")
    ) {
      pepBlockedToolCalls += 1;
    }
  }
  if (toolAttemptRows.length === 0 || agentSelectedToolCalls === 0) {
    throw new Error("Real OpenClaw run did not exercise the Tool Attempt PEP");
  }
  if (unauthorizedSensitiveExecutions !== 0) {
    throw new Error("A sensitive tool executed without a consumed WakeOnCue Permit");
  }

  const version = await runCommand(openClawBin, ["--version"], commonOpenClawEnv);
  const nodeVersion = await runCommand(join(openClawNodeBinDir, "node"), ["--version"], {
    ...process.env,
  });
  const taskApi = await fetch(`http://127.0.0.1:${apiPort}/v1/tasks/${runtime.taskId}`);
  if (!taskApi.ok) throw new Error(`Task timeline API returned HTTP ${taskApi.status}`);

  artifact = {
    ...artifact,
    status: "PASS",
    completedAt: new Date().toISOString(),
    durationMs: Date.now() - startedAt.getTime(),
    versions: {
      wakeOnCueNode: process.version,
      openClawNode: nodeVersion.stdout.trim(),
      openClaw: version.stdout.trim(),
    },
    processes: {
      openClawPid: gateway.pid,
      apiPid: api.pid,
      workerPid: worker.pid,
      openClawHealthOk: health["ok"] === true,
      loadedPlugins: ["wakeoncue-guard"],
    },
    chain: {
      cueEventId: ingestBody.event.eventId,
      taskId: runtime.taskId,
      runtimeRunId: runtime.runtimeRunId,
      activationRunId: runtime.externalRunId,
      agentRunId: runtime.agentRunId,
      callbackStatuses: callbackRows.map((row) => row.status),
      taskStatus: runtime.taskStatus,
      runtimeStatus: runtime.runtimeStatus,
    },
    contract: {
      goal: runtime.contract.goal,
      successCriteria: runtime.contract.successCriteria,
      constraints: runtime.contract.constraints,
      capabilityScope: runtime.contract.capabilityScope,
      includesToolPlan: JSON.stringify(runtime.contract).includes("toolSteps"),
    },
    runtimeEvidence: {
      sessionFile: sessionPath,
      agentSelectedToolCalls,
      pepBlockedToolCalls,
      toolAttempts: toolAttemptRows.map((row) => ({
        tool: row.tool,
        status: row.status,
        policyDecision: row.policy_decision,
        reasonCode: row.reason_code,
      })),
      unauthorizedSensitiveExecutions,
      modelTurnCompleted: true,
    },
    idempotency: {
      duplicateCueInserted: replayedBody.inserted,
      taskCountBeforeReplay,
      taskCountAfterReplay,
      callbackCountAfterReplay,
      duplicateActivationReturnedSameRunId: true,
      duplicateExternalSideEffects: 0,
    },
    logs: Object.fromEntries(managed.map(({ label }) => [label, join(runDir, `${label}.log`)])),
  };
  await writeFile(artifactPath, `${JSON.stringify(artifact, null, 2)}\n`, { mode: 0o600 });
  process.stdout.write(`${JSON.stringify({ artifactPath, ...artifact }, null, 2)}\n`);
} catch (error) {
  artifact = {
    ...artifact,
    completedAt: new Date().toISOString(),
    durationMs: Date.now() - startedAt.getTime(),
    error: error instanceof Error ? error.message : String(error),
    logs: Object.fromEntries(managed.map(({ label }) => [label, join(runDir, `${label}.log`)])),
  };
  await writeFile(artifactPath, `${JSON.stringify(artifact, null, 2)}\n`, { mode: 0o600 });
  process.stderr.write(`${JSON.stringify({ artifactPath, ...artifact }, null, 2)}\n`);
  process.exitCode = 1;
} finally {
  await stopManaged();
}
