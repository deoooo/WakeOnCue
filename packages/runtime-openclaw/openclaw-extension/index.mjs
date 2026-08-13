import { createHash, createHmac } from "node:crypto";

import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

const taskContextByRun = new Map();
const executingAttempts = new Map();
const markerPrefix = "WAKEONCUE_TASK_CONTEXT:";

function canonicalJson(value) {
  if (value === null || typeof value === "boolean" || typeof value === "string") {
    return JSON.stringify(value);
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new TypeError("Non-finite tool argument");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (typeof value === "object") {
    return `{${Object.entries(value)
      .filter(([, entry]) => entry !== undefined)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, entry]) => `${JSON.stringify(key)}:${canonicalJson(entry)}`)
      .join(",")}}`;
  }
  throw new TypeError(`Unsupported tool argument type: ${typeof value}`);
}

function resultDigest(value) {
  return `sha256:${createHash("sha256").update(canonicalJson(value)).digest("hex")}`;
}

function parseTaskContext(prompt) {
  const markerLine = String(prompt ?? "")
    .split("\n")
    .find((line) => line.startsWith(markerPrefix));
  if (!markerLine) return undefined;
  try {
    const value = JSON.parse(markerLine.slice(markerPrefix.length));
    if (
      value?.specVersion !== "wakeoncue.openclaw.task-context/v1" ||
      typeof value.taskId !== "string" ||
      typeof value.runtimeRunId !== "string"
    ) {
      return undefined;
    }
    return value;
  } catch {
    return undefined;
  }
}

async function callback(context, status, extra = {}) {
  const callbackUrl = context.callbackUrl ?? process.env.WAKEONCUE_RUNTIME_CALLBACK_URL;
  const secret = process.env.WAKEONCUE_RUNTIME_CALLBACK_SECRET;
  if (!callbackUrl || !secret) {
    throw new Error("WakeOnCue callback URL and secret are required for correlated runs");
  }
  const body = JSON.stringify({
    specVersion: "wakeoncue.runtime.callback/v1",
    runtimeRunId: context.runtimeRunId,
    taskId: context.taskId,
    agentRunId: context.agentRunId,
    status,
    occurredAt: new Date().toISOString(),
    evidenceRefs: [],
    ...extra,
  });
  const timestamp = Math.floor(Date.now() / 1_000);
  const signature = `v1=${createHmac("sha256", secret)
    .update(`${timestamp}.${body}`)
    .digest("hex")}`;
  let lastError;
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      const response = await fetch(callbackUrl, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-wakeoncue-timestamp": String(timestamp),
          "x-wakeoncue-signature": signature,
        },
        body,
        signal: AbortSignal.timeout(3_000),
      });
      if (response.ok) return;
      lastError = new Error(`WakeOnCue callback rejected with HTTP ${response.status}`);
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError instanceof Error ? lastError : new Error("WakeOnCue callback failed");
}

async function signedPolicyPost(url, bodyValue) {
  const secret = process.env.WAKEONCUE_RUNTIME_PEP_SECRET;
  if (!url || !secret) throw new Error("WakeOnCue PEP URL and secret are required");
  const body = JSON.stringify(bodyValue);
  const timestamp = Math.floor(Date.now() / 1_000);
  const signature = `v1=${createHmac("sha256", secret)
    .update(`${timestamp}.${body}`)
    .digest("hex")}`;
  const response = await fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-wakeoncue-timestamp": String(timestamp),
      "x-wakeoncue-signature": signature,
    },
    body,
    signal: AbortSignal.timeout(5_000),
  });
  const parsed = await response.json();
  if (!response.ok) {
    throw new Error(
      `WakeOnCue PEP rejected with HTTP ${response.status}: ${parsed?.code ?? "unknown"}`,
    );
  }
  return parsed;
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

export default definePluginEntry({
  id: "wakeoncue-guard",
  name: "WakeOnCue Guard",
  description: "WakeOnCue lifecycle and policy enforcement bridge",
  register(api) {
    if (
      process.env.WAKEONCUE_ENABLE_CONTROLLED_TEST_TOOL === "1" &&
      process.env.WAKEONCUE_TEST_SINK_URL
    ) {
      api.registerTool({
        name: "file_send",
        label: "Controlled File Send",
        description:
          "Send one named attachment to one recipient through the controlled WakeOnCue E2E sink.",
        parameters: {
          type: "object",
          additionalProperties: false,
          required: ["recipient", "attachment"],
          properties: {
            recipient: { type: "string", minLength: 1 },
            attachment: { type: "string", minLength: 1 },
          },
        },
        async execute(toolCallId, params) {
          const response = await fetch(process.env.WAKEONCUE_TEST_SINK_URL, {
            method: "POST",
            headers: {
              authorization: `Bearer ${process.env.WAKEONCUE_TEST_SINK_TOKEN ?? ""}`,
              "content-type": "application/json",
              "idempotency-key": toolCallId,
            },
            body: JSON.stringify(params),
            signal: AbortSignal.timeout(5_000),
          });
          if (!response.ok)
            throw new Error(`Controlled send sink returned HTTP ${response.status}`);
          const receipt = await response.json();
          return {
            content: [{ type: "text", text: JSON.stringify(receipt) }],
            details: receipt,
          };
        },
      });
    }

    api.on(
      "before_agent_run",
      async (event, ctx) => {
        const context = parseTaskContext(event.prompt);
        const runId = event.runId ?? ctx.runId;
        if (!context || !runId) return { outcome: "pass" };
        const correlated = { ...context, agentRunId: runId };
        taskContextByRun.set(runId, correlated);
        await callback(correlated, "RUNNING");
        return { outcome: "pass" };
      },
      { priority: 100 },
    );

    api.on(
      "before_tool_call",
      async (event, ctx) => {
        const runId = event.runId ?? ctx.runId;
        const context = runId ? taskContextByRun.get(runId) : undefined;
        if (!runId || !context) return;
        const toolCallId = event.toolCallId ?? ctx.toolCallId;
        if (!toolCallId) {
          return { block: true, blockReason: "WAKEONCUE_TOOL_CALL_ID_REQUIRED" };
        }
        const policyUrl = context.policyUrl;
        const request = {
          specVersion: "wakeoncue.runtime.tool-attempt/v1",
          taskId: context.taskId,
          runtimeRunId: context.runtimeRunId,
          agentRunId: context.agentRunId,
          toolCallId,
          tool: event.toolName,
          arguments: event.params,
        };
        const deadline = Date.now() + Number(process.env.WAKEONCUE_APPROVAL_WAIT_MS ?? "90000");
        while (true) {
          const response = await signedPolicyPost(policyUrl, request);
          const authorization = response?.authorization;
          const attemptId = authorization?.attempt?.attempt?.attemptId;
          if (!attemptId || typeof authorization?.decision !== "string") {
            throw new Error("WakeOnCue PEP returned an invalid authorization response");
          }
          if (authorization.decision === "ALLOW") {
            executingAttempts.set(`${runId}:${toolCallId}`, {
              ...context,
              attemptId,
              toolCallId,
              resultUrl: policyUrl.replace(/\/tool-attempts\/openclaw$/u, "/tool-results/openclaw"),
            });
            return;
          }
          if (authorization.decision === "DENY") {
            return {
              block: true,
              blockReason: `WAKEONCUE_DENIED:${authorization.reasonCode}:${attemptId}`,
            };
          }
          if (Date.now() >= deadline) {
            return {
              block: true,
              blockReason: `WAKEONCUE_APPROVAL_TIMEOUT:${attemptId}`,
            };
          }
          await sleep(750);
        }
      },
      { priority: 1000 },
    );

    api.on("after_tool_call", async (event, ctx) => {
      const runId = event.runId ?? ctx.runId;
      const toolCallId = event.toolCallId ?? ctx.toolCallId;
      const execution =
        runId && toolCallId ? executingAttempts.get(`${runId}:${toolCallId}`) : undefined;
      if (!execution) return;
      try {
        await signedPolicyPost(execution.resultUrl, {
          specVersion: "wakeoncue.runtime.tool-result/v1",
          attemptId: execution.attemptId,
          taskId: execution.taskId,
          runtimeRunId: execution.runtimeRunId,
          agentRunId: execution.agentRunId,
          toolCallId,
          occurredAt: new Date().toISOString(),
          status: event.error ? "UNKNOWN" : "SUCCEEDED",
          ...(event.result === undefined ? {} : { resultDigest: resultDigest(event.result) }),
          ...(event.error ? { errorCode: "OPENCLAW_TOOL_ERROR" } : {}),
          ...(typeof event.durationMs === "number" ? { durationMs: event.durationMs } : {}),
        });
      } finally {
        executingAttempts.delete(`${runId}:${toolCallId}`);
      }
    });

    api.on("agent_end", async (event, ctx) => {
      const runId = event.runId ?? ctx.runId;
      const context = runId ? taskContextByRun.get(runId) : undefined;
      if (!context) return;
      try {
        await callback(context, event.success ? "SUCCEEDED" : "FAILED", {
          summary: event.success ? "OpenClaw agent turn completed" : "OpenClaw agent turn failed",
        });
      } finally {
        taskContextByRun.delete(runId);
        for (const key of executingAttempts.keys()) {
          if (key.startsWith(`${runId}:`)) executingAttempts.delete(key);
        }
      }
    });
  },
});
