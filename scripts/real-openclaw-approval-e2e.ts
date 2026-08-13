import { randomBytes } from "node:crypto";
import { spawn, type ChildProcess } from "node:child_process";
import { createWriteStream } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { createServer as createHttpServer } from "node:http";
import { createServer as createNetServer } from "node:net";
import { join, resolve } from "node:path";

import type { RuntimeToolAttemptRequest, TaskContract } from "@wakeoncue/contracts";
import { canonicalJson } from "@wakeoncue/core";
import { OpenClawRuntimeAdapter } from "@wakeoncue/runtime-openclaw";
import { signWebhook } from "@wakeoncue/source-webhook";
import { migrateDatabase, openDatabase, SqliteWakeStore } from "@wakeoncue/storage-sqlite";

const root = resolve(import.meta.dirname, "..");
const openClawBin = process.env["WAKEONCUE_OPENCLAW_BIN"];
const openClawNodeBinDir = process.env["WAKEONCUE_OPENCLAW_NODE_BIN_DIR"];
if (!openClawBin || !openClawNodeBinDir) {
  throw new Error("Set WAKEONCUE_OPENCLAW_BIN and WAKEONCUE_OPENCLAW_NODE_BIN_DIR");
}

const startedAt = new Date();
const label = startedAt.toISOString().replaceAll(/[:.]/gu, "-");
const runDir = join(root, ".runtime", "real-openclaw-approval-e2e", label);
const runtimeDir = join(root, ".runtime", "openclaw-approval-e2e");
const stateDir = join(runtimeDir, "state");
const configPath = join(stateDir, "openclaw.json");
const databasePath = join(runDir, "wakeoncue.sqlite");
const artifactPath = join(runDir, "result.json");
const controlledAttachmentPath = join(runtimeDir, "workspace", "final-quote.pdf");
await mkdir(runDir, { recursive: true, mode: 0o700 });

const gatewayToken = randomBytes(32).toString("hex");
const hookToken = randomBytes(32).toString("hex");
const callbackSecret = randomBytes(32).toString("hex");
const pepSecret = randomBytes(32).toString("hex");
const approvalToken = randomBytes(32).toString("hex");
const sinkToken = randomBytes(32).toString("hex");
const managed: Array<{ label: string; child: ChildProcess }> = [];

async function freePort(): Promise<number> {
  return new Promise((resolvePort, reject) => {
    const server = createNetServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") return reject(new Error("No allocated port"));
      server.close((error) => (error ? reject(error) : resolvePort(address.port)));
    });
  });
}

async function runCommand(
  command: string,
  args: string[],
  env: NodeJS.ProcessEnv,
): Promise<{ stdout: string }> {
  return new Promise((resolveRun, reject) => {
    const child = spawn(command, args, { cwd: root, env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", (chunk) => (stdout += String(chunk)));
    child.stderr?.on("data", (chunk) => (stderr += String(chunk)));
    child.once("exit", (code) =>
      code === 0 ? resolveRun({ stdout }) : reject(new Error(`${command} failed: ${stderr}`)),
    );
  });
}

function startManaged(
  processLabel: string,
  command: string,
  args: string[],
  env: NodeJS.ProcessEnv,
): ChildProcess {
  const output = createWriteStream(join(runDir, `${processLabel}.log`), {
    flags: "a",
    mode: 0o600,
  });
  const child = spawn(command, args, { cwd: root, env, stdio: ["ignore", "pipe", "pipe"] });
  child.stdout?.pipe(output, { end: false });
  child.stderr?.pipe(output, { end: false });
  child.once("exit", (code, signal) => {
    output.write(`\n[process-exit] code=${String(code)} signal=${String(signal)}\n`);
    output.end();
  });
  managed.push({ label: processLabel, child });
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
    `${description} timed out${lastError instanceof Error ? `: ${lastError.message}` : ""}`,
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

const taskContract: TaskContract = {
  contractVersion: "wakeoncue.task/v1",
  taskId: "task_real_approval_e2e",
  subject: "subject-controlled-approval-e2e",
  goal: "Send attachment final-quote.pdf to recipient contact:zhangsan now.",
  successCriteria: [
    "The controlled external receiver returns a delivery receipt",
    "The exact recipient and attachment match the approved parameters",
  ],
  constraints: [
    "Choose the available tool yourself",
    "Do not bypass WakeOnCue approval or claim delivery without a tool receipt",
  ],
  contextRefs: [controlledAttachmentPath],
  runtime: { adapter: "openclaw", profile: "default" },
  capabilityScope: ["task.plan", "evidence.read"],
  approvalRequiredFor: ["external.send"],
  idempotencyKey: `approval-e2e:${label}`,
};

let sinkServer: ReturnType<typeof createHttpServer> | undefined;
let artifact: Record<string, unknown> = {
  specVersion: "wakeoncue.evidence.real-openclaw-approval/v1",
  status: "FAIL",
  startedAt: startedAt.toISOString(),
  boundaries: {
    runtime: "real OpenClaw process, real configured model, real before/after tool hooks",
    externalWrite:
      "controlled loopback HTTP sink registered only when WAKEONCUE_TEST_SINK_URL is set",
    productionProvider: false,
  },
};

try {
  const [gatewayPort, apiPort, sinkPort] = await Promise.all([freePort(), freePort(), freePort()]);
  const sideEffects = new Map<
    string,
    { recipient: string; attachment: string; receiptId: string }
  >();
  sinkServer = createHttpServer((request, response) => {
    let raw = "";
    request.on("data", (chunk) => (raw += String(chunk)));
    request.on("end", () => {
      if (request.headers.authorization !== `Bearer ${sinkToken}`) {
        response.writeHead(401).end();
        return;
      }
      const key = String(request.headers["idempotency-key"] ?? "");
      const body = JSON.parse(raw) as { recipient: string; attachment: string };
      const existing = sideEffects.get(key);
      const receipt =
        existing ??
        ({
          ...body,
          receiptId: `controlled-receipt-${sideEffects.size + 1}`,
        } satisfies { recipient: string; attachment: string; receiptId: string });
      sideEffects.set(key, receipt);
      response.writeHead(existing ? 200 : 201, { "content-type": "application/json" });
      response.end(JSON.stringify(receipt));
    });
  });
  await new Promise<void>((resolveListen, reject) => {
    sinkServer?.once("error", reject);
    sinkServer?.listen(sinkPort, "127.0.0.1", resolveListen);
  });

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
    WAKEONCUE_OPENCLAW_RUNTIME_DIR: runtimeDir,
    WAKEONCUE_OPENCLAW_PORT: String(gatewayPort),
    WAKEONCUE_OPENCLAW_COPY_AUTH: "1",
  });
  await runCommand(process.execPath, ["scripts/import-openclaw-auth.mjs"], {
    ...commonOpenClawEnv,
    WAKEONCUE_OPENCLAW_RUNTIME_DIR: runtimeDir,
    WAKEONCUE_OPENCLAW_IMPORT_AUTH: "1",
    WAKEONCUE_OPENCLAW_BIN: openClawBin,
    WAKEONCUE_OPENCLAW_NODE_BIN_DIR: openClawNodeBinDir,
  });
  await mkdir(join(runtimeDir, "workspace"), { recursive: true, mode: 0o700 });
  await writeFile(
    controlledAttachmentPath,
    "WakeOnCue controlled approval fixture. No personal or production data.\n",
    { mode: 0o600 },
  );

  const database = openDatabase(databasePath);
  migrateDatabase(database);
  const now = new Date().toISOString();
  database
    .prepare(
      `INSERT INTO episodes(episode_id, subject, correlation_key, state_json, version, updated_at)
       VALUES ('ep_real_approval_e2e', ?, 'approval-e2e', '{}', 1, ?)`,
    )
    .run(taskContract.subject, now);
  database
    .prepare(
      `INSERT INTO decisions(
        decision_id, episode_id, decision, reason_codes_json, evidence_refs_json,
        strategy_version, record_json, created_at
      ) VALUES (
        'dec_real_approval_e2e', 'ep_real_approval_e2e', 'WAKE_AGENT', '[]', '[]',
        'approval-e2e/v1', '{}', ?
      )`,
    )
    .run(now);
  database
    .prepare(
      `INSERT INTO tasks(
        task_id, decision_id, idempotency_key, contract_json, status, created_at, updated_at
      ) VALUES (?, 'dec_real_approval_e2e', ?, ?, 'RUN_ACCEPTED', ?, ?)`,
    )
    .run(taskContract.taskId, taskContract.idempotencyKey, canonicalJson(taskContract), now, now);
  database
    .prepare(
      `INSERT INTO runtime_runs(
        runtime_run_id, task_id, adapter, external_run_id, agent_run_id,
        idempotency_key, status, last_observed_at, record_json
      ) VALUES (
        'run_real_approval_e2e', ?, 'openclaw', NULL, NULL, ?, 'RUN_ACCEPTED', ?, '{}'
      )`,
    )
    .run(taskContract.taskId, taskContract.idempotencyKey, now);
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
      WAKEONCUE_RUNTIME_CALLBACK_URL: callbackUrl,
      WAKEONCUE_RUNTIME_PEP_SECRET: pepSecret,
      WAKEONCUE_APPROVAL_WAIT_MS: "120000",
      WAKEONCUE_ENABLE_CONTROLLED_TEST_TOOL: "1",
      WAKEONCUE_TEST_SINK_URL: `http://127.0.0.1:${sinkPort}/send`,
      WAKEONCUE_TEST_SINK_TOKEN: sinkToken,
    },
  );
  const api = startManaged("api", process.execPath, ["--import", "tsx", "apps/api/src/main.ts"], {
    ...process.env,
    WAKEONCUE_DATABASE_PATH: databasePath,
    WAKEONCUE_API_PORT: String(apiPort),
    WAKEONCUE_RUNTIME_CALLBACK_SECRET: callbackSecret,
    WAKEONCUE_RUNTIME_PEP_SECRET: pepSecret,
    WAKEONCUE_APPROVAL_ADMIN_TOKEN: approvalToken,
    WAKEONCUE_PERMIT_TTL_SECONDS: "60",
    WAKEONCUE_LOG_LEVEL: "info",
  });
  await waitFor(
    "OpenClaw health",
    async () => {
      if (gateway.exitCode !== null) throw new Error(`OpenClaw exited ${gateway.exitCode}`);
      const response = await fetch(`http://127.0.0.1:${gatewayPort}/health`);
      return response.ok ? true : undefined;
    },
    60_000,
  );
  await waitFor(
    "WakeOnCue API",
    async () => {
      if (api.exitCode !== null) throw new Error(`API exited ${api.exitCode}`);
      return (await fetch(`http://127.0.0.1:${apiPort}/ready`)).ok ? true : undefined;
    },
    30_000,
  );

  let sinkCountBeforeApproval = -1;
  const approve = waitFor(
    "pending exact file_send approval",
    async () => {
      const response = await fetch(`http://127.0.0.1:${apiPort}/v1/approvals`, {
        headers: { authorization: `Bearer ${approvalToken}` },
      });
      if (!response.ok) return undefined;
      const body = (await response.json()) as {
        approvals: Array<{
          attempt: {
            attemptId: string;
            tool: string;
            arguments: Record<string, unknown>;
          };
        }>;
      };
      const pending = body.approvals[0];
      if (!pending) return undefined;
      if (
        pending.attempt.tool !== "file_send" ||
        pending.attempt.arguments["recipient"] !== "contact:zhangsan" ||
        pending.attempt.arguments["attachment"] !== controlledAttachmentPath
      ) {
        throw new Error("Agent requested parameters outside the expected approval fixture");
      }
      sinkCountBeforeApproval = sideEffects.size;
      const approved = await fetch(
        `http://127.0.0.1:${apiPort}/v1/approvals/${pending.attempt.attemptId}`,
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${approvalToken}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({ decision: "APPROVE_ONCE" }),
        },
      );
      if (!approved.ok) throw new Error(`Approval returned HTTP ${approved.status}`);
      return pending.attempt.attemptId;
    },
    120_000,
  );

  const adapter = new OpenClawRuntimeAdapter({
    baseUrl: `http://127.0.0.1:${gatewayPort}`,
    hookToken,
    agentId: "main",
    model: "modelstudio/glm-5",
    pluginVerified: true,
    agentTimeoutSeconds: 180,
  });
  const receipt = await adapter.activate(taskContract, {
    runtimeRunId: "run_real_approval_e2e",
    idempotencyKey: taskContract.idempotencyKey,
    callbackUrl,
  });
  const receiptDatabase = openDatabase(databasePath);
  receiptDatabase
    .prepare("UPDATE runtime_runs SET external_run_id = ? WHERE runtime_run_id = ?")
    .run(receipt.externalRunId, "run_real_approval_e2e");
  receiptDatabase.close();
  const attemptId = await approve;

  const completed = await waitFor(
    "approved tool execution",
    () => {
      const currentDatabase = openDatabase(databasePath);
      try {
        const store = new SqliteWakeStore(currentDatabase);
        const attempt = store.getToolAttempt(attemptId);
        const runtime = store.getRuntimeRun("run_real_approval_e2e");
        return attempt?.status === "SUCCEEDED" && runtime?.status === "SUCCEEDED"
          ? { attempt, runtime }
          : undefined;
      } finally {
        currentDatabase.close();
      }
    },
    240_000,
  );

  const attackDatabase = openDatabase(databasePath);
  const attempt = new SqliteWakeStore(attackDatabase).getToolAttempt(attemptId);
  const delivery = attackDatabase
    .prepare("SELECT status FROM deliveries WHERE consumer = 'tool-pep' AND idempotency_key = ?")
    .get(`tool:${attemptId}`) as { status: string } | undefined;
  const permitEventTypes = attackDatabase
    .prepare("SELECT event_type FROM permit_events WHERE attempt_id = ? ORDER BY occurred_at")
    .all(attemptId)
    .map((row) => (row as { event_type: string }).event_type);
  attackDatabase.close();
  if (!attempt?.permit?.consumedAt) throw new Error("Approved Permit was not consumed");
  if (sinkCountBeforeApproval !== 0 || sideEffects.size !== 1) {
    throw new Error("Controlled external side effect did not occur exactly once after approval");
  }
  const sinkReceipt = [...sideEffects.values()][0];
  if (
    sinkReceipt?.recipient !== "contact:zhangsan" ||
    sinkReceipt.attachment !== controlledAttachmentPath
  ) {
    throw new Error("Controlled receiver observed changed parameters");
  }

  const replayRequest: RuntimeToolAttemptRequest = {
    specVersion: "wakeoncue.runtime.tool-attempt/v1",
    taskId: taskContract.taskId,
    runtimeRunId: "run_real_approval_e2e",
    agentRunId: completed.runtime.agentRunId ?? "",
    toolCallId: attempt.attempt.toolCallId,
    tool: attempt.attempt.tool,
    arguments: attempt.attempt.arguments,
  };
  const replayBody = JSON.stringify(replayRequest);
  const replayTimestamp = Math.floor(Date.now() / 1_000);
  const replayResponse = await fetch(
    `http://127.0.0.1:${apiPort}/v1/runtime/tool-attempts/openclaw`,
    {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-wakeoncue-timestamp": String(replayTimestamp),
        "x-wakeoncue-signature": signWebhook(replayBody, replayTimestamp, pepSecret),
      },
      body: replayBody,
    },
  );
  const replayAuthorization = (await replayResponse.json()) as {
    authorization?: { decision?: string; reasonCode?: string };
  };
  if (
    replayAuthorization.authorization?.decision !== "DENY" ||
    replayAuthorization.authorization.reasonCode !== "PERMIT_ALREADY_CONSUMED" ||
    sideEffects.size !== 1
  ) {
    throw new Error("Consumed Permit replay was not denied");
  }

  const version = await runCommand(openClawBin, ["--version"], commonOpenClawEnv);
  const nodeVersion = await runCommand(join(openClawNodeBinDir, "node"), ["--version"], {
    ...process.env,
  });
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
    chain: {
      taskId: taskContract.taskId,
      runtimeRunId: completed.runtime.runtimeRunId,
      activationRunId: receipt.externalRunId,
      agentRunId: completed.runtime.agentRunId,
      attemptId,
      permitId: attempt.permit.permitId,
      permitEventTypes,
      toolStatus: completed.attempt.status,
      toolDeliveryStatus: delivery?.status,
      runtimeStatus: completed.runtime.status,
    },
    enforcement: {
      sinkCountBeforeApproval,
      sinkCountAfterApproval: sideEffects.size,
      exactRecipient: sinkReceipt.recipient,
      exactAttachment: sinkReceipt.attachment,
      permitConsumedAt: attempt.permit.consumedAt,
      consumedPermitReplayDecision: replayAuthorization.authorization,
      duplicateExternalSideEffects: 0,
    },
    logs: Object.fromEntries(
      managed.map(({ label: processLabel }) => [processLabel, join(runDir, `${processLabel}.log`)]),
    ),
  };
  await writeFile(artifactPath, `${JSON.stringify(artifact, null, 2)}\n`, { mode: 0o600 });
  process.stdout.write(`${JSON.stringify({ artifactPath, ...artifact }, null, 2)}\n`);
} catch (error) {
  artifact = {
    ...artifact,
    completedAt: new Date().toISOString(),
    durationMs: Date.now() - startedAt.getTime(),
    error: error instanceof Error ? error.message : String(error),
    logs: Object.fromEntries(
      managed.map(({ label: processLabel }) => [processLabel, join(runDir, `${processLabel}.log`)]),
    ),
  };
  await writeFile(artifactPath, `${JSON.stringify(artifact, null, 2)}\n`, { mode: 0o600 });
  process.stderr.write(`${JSON.stringify({ artifactPath, ...artifact }, null, 2)}\n`);
  process.exitCode = 1;
} finally {
  await stopManaged();
  await new Promise<void>(
    (resolveClose) => sinkServer?.close(() => resolveClose()) ?? resolveClose(),
  );
}
