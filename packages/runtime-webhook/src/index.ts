import { createHmac } from "node:crypto";
import { Value } from "@sinclair/typebox/value";

import type { TaskContract } from "@wakeoncue/contracts";
import {
  activationReceipt,
  RuntimeStatusSchema,
  RuntimeTransportError,
  type RuntimeActivationContext,
  type RuntimeActivationReceipt,
  type RuntimeAdapter,
  type RuntimeStatusReceipt,
} from "@wakeoncue/runtime-sdk";

interface WebhookRuntimeOptions {
  endpoint: string;
  secret: string;
  timeoutMs?: number;
  fetch?: typeof fetch;
}

export class WebhookRuntimeAdapter implements RuntimeAdapter {
  readonly adapterId = "runtime-webhook";
  readonly contractVersion = "wakeoncue.runtime.webhook/v1";
  readonly capabilities = {
    preToolInterception: false,
    idempotencyQuery: true,
    cancellation: false,
    statusPolling: true,
    callbacks: true,
  } as const;

  private readonly fetch: typeof fetch;

  constructor(private readonly options: WebhookRuntimeOptions) {
    this.fetch = options.fetch ?? globalThis.fetch;
  }

  async activate(
    contract: TaskContract,
    context: RuntimeActivationContext,
  ): Promise<RuntimeActivationReceipt> {
    const body = JSON.stringify({
      specVersion: this.contractVersion,
      contract,
      runtimeRunId: context.runtimeRunId,
      ...(context.callbackUrl ? { callbackUrl: context.callbackUrl } : {}),
    });
    const timestamp = Math.floor(Date.now() / 1_000);
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.options.timeoutMs ?? 10_000);
    try {
      const response = await this.fetch(this.options.endpoint, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "idempotency-key": context.idempotencyKey,
          "x-wakeoncue-runtime-timestamp": String(timestamp),
          "x-wakeoncue-runtime-signature": `v1=${createHmac("sha256", this.options.secret)
            .update(`${timestamp}.${body}`)
            .digest("hex")}`,
        },
        body,
        signal: controller.signal,
      });
      const raw = (await response.json()) as Record<string, unknown>;
      if (!response.ok || typeof raw["externalRunId"] !== "string") {
        throw new RuntimeTransportError(
          `Runtime rejected activation: HTTP ${response.status}`,
          false,
        );
      }
      return activationReceipt({
        externalRunId: raw["externalRunId"],
        status: "RUN_ACCEPTED",
        acceptedAt: new Date().toISOString(),
        providerReceipt: raw,
      });
    } catch (error) {
      if (error instanceof RuntimeTransportError) throw error;
      throw new RuntimeTransportError(
        error instanceof Error ? error.message : "Runtime activation failed",
        true,
      );
    } finally {
      clearTimeout(timeout);
    }
  }

  async getStatus(externalRunId: string): Promise<RuntimeStatusReceipt> {
    const response = await this.fetch(
      `${this.options.endpoint.replace(/\/$/u, "")}/${encodeURIComponent(externalRunId)}`,
    );
    const raw = (await response.json()) as Record<string, unknown>;
    if (!response.ok || !Value.Check(RuntimeStatusSchema, raw["status"])) {
      throw new RuntimeTransportError(`Runtime status failed: HTTP ${response.status}`, false);
    }
    return {
      externalRunId,
      status: raw["status"],
      observedAt: new Date().toISOString(),
      evidenceRefs: [],
    };
  }
}
