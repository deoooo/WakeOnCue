import type { TaskContract } from "@wakeoncue/contracts";
import {
  activationReceipt,
  RuntimeTransportError,
  assertRuntimeCapabilityScope,
  type RuntimeActivationContext,
  type RuntimeActivationReceipt,
  type RuntimeAdapter,
  type RuntimeStatusReceipt,
} from "@wakeoncue/runtime-sdk";

export const OPENCLAW_VERIFIED_VERSION = "2026.7.1-2";

interface OpenClawRuntimeOptions {
  baseUrl: string;
  hookToken: string;
  agentId?: string;
  model?: string;
  timeoutMs?: number;
  agentTimeoutSeconds?: number;
  pluginVerified?: boolean;
  fetch?: typeof fetch;
}

interface OpenClawHookResponse {
  runId?: string;
  acceptedAt?: string;
  ok?: boolean;
  status?: string;
}

function taskMessage(contract: TaskContract, context: RuntimeActivationContext): string {
  const policyUrl = context.callbackUrl?.replace(
    /\/runtime\/callbacks\/openclaw$/u,
    "/runtime/tool-attempts/openclaw",
  );
  const marker = JSON.stringify({
    specVersion: "wakeoncue.openclaw.task-context/v1",
    taskId: contract.taskId,
    runtimeRunId: context.runtimeRunId,
    capabilityScope: contract.capabilityScope,
    approvalRequiredFor: contract.approvalRequiredFor,
    callbackUrl: context.callbackUrl,
    policyUrl,
  });
  return [
    `WAKEONCUE_TASK_CONTEXT:${marker}`,
    "You are activated by WakeOnCue to own the following outcome.",
    `Goal: ${contract.goal}`,
    `Success criteria: ${contract.successCriteria.join("; ")}`,
    `Constraints: ${contract.constraints.join("; ")}`,
    `Evidence refs: ${contract.contextRefs.join(", ")}`,
    contract.deadline ? `Deadline: ${contract.deadline}` : "Deadline: not specified",
    `Initial capability scope: ${contract.capabilityScope.join(", ") || "none"}`,
    "Plan the work yourself. Do not claim completion without verifiable evidence.",
    "Any tool call may be blocked by the WakeOnCue policy enforcement plugin.",
  ].join("\n");
}

export class OpenClawRuntimeAdapter implements RuntimeAdapter {
  readonly adapterId = "openclaw";
  readonly contractVersion = "wakeoncue.runtime.openclaw/v1";
  readonly capabilities;
  private readonly fetch: typeof fetch;

  constructor(private readonly options: OpenClawRuntimeOptions) {
    this.fetch = options.fetch ?? globalThis.fetch;
    this.capabilities = {
      preToolInterception: options.pluginVerified === true,
      idempotencyQuery: false,
      cancellation: false,
      statusPolling: false,
      callbacks: options.pluginVerified === true,
    } as const;
  }

  async activate(
    contract: TaskContract,
    context: RuntimeActivationContext,
  ): Promise<RuntimeActivationReceipt> {
    assertRuntimeCapabilityScope(this.capabilities, contract.capabilityScope);
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.options.timeoutMs ?? 15_000);
    const payload = {
      message: taskMessage(contract, context),
      name: `WakeOnCue ${contract.taskId}`,
      idempotencyKey: context.idempotencyKey,
      ...(this.options.agentId ? { agentId: this.options.agentId } : {}),
      ...(this.options.model ? { model: this.options.model } : {}),
      wakeMode: "now",
      deliver: false,
      timeoutSeconds: this.options.agentTimeoutSeconds ?? 120,
    };
    try {
      const response = await this.fetch(`${this.options.baseUrl.replace(/\/$/u, "")}/hooks/agent`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${this.options.hookToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(payload),
        signal: controller.signal,
      });
      const raw = (await response.json()) as OpenClawHookResponse;
      if (!response.ok) {
        throw new RuntimeTransportError(
          `OpenClaw rejected activation: HTTP ${response.status}`,
          false,
        );
      }
      const runId = raw.runId;
      if (!runId) {
        throw new RuntimeTransportError("OpenClaw activation response omitted runId", true);
      }
      return activationReceipt({
        externalRunId: runId,
        status: "RUN_ACCEPTED",
        acceptedAt: raw.acceptedAt ?? new Date().toISOString(),
        providerReceipt: raw,
      });
    } catch (error) {
      if (error instanceof RuntimeTransportError) throw error;
      throw new RuntimeTransportError(
        error instanceof Error ? error.message : "OpenClaw activation failed",
        true,
      );
    } finally {
      clearTimeout(timeout);
    }
  }

  getStatus(): Promise<RuntimeStatusReceipt> {
    return Promise.reject(
      new RuntimeTransportError(
        "OpenClaw hook activation uses authenticated plugin callbacks; polling is unavailable",
        false,
      ),
    );
  }
}

export function renderOpenClawTaskMessage(
  contract: TaskContract,
  context: RuntimeActivationContext,
): string {
  return taskMessage(contract, context);
}
