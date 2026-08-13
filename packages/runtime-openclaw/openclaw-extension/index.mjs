import { createHmac } from "node:crypto";

import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

const taskContextByRun = new Map();
const markerPrefix = "WAKEONCUE_TASK_CONTEXT:";

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

export default definePluginEntry({
  id: "wakeoncue-guard",
  name: "WakeOnCue Guard",
  description: "WakeOnCue lifecycle and policy enforcement bridge",
  register(api) {
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
        if (!runId || !taskContextByRun.has(runId)) return;
        return {
          block: true,
          blockReason: "WAKEONCUE_PEP_REQUIRED",
        };
      },
      { priority: 1000 },
    );

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
      }
    });
  },
});
