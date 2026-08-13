import { Type, type Static } from "@sinclair/typebox";
import { Value } from "@sinclair/typebox/value";

import type { TaskContract } from "@wakeoncue/contracts";
import { canonicalJson, sha256 } from "@wakeoncue/core";

export const RuntimeStatusSchema = Type.Union([
  Type.Literal("RUN_ACCEPTED"),
  Type.Literal("RUNNING"),
  Type.Literal("WAITING_APPROVAL"),
  Type.Literal("SUCCEEDED"),
  Type.Literal("FAILED"),
  Type.Literal("CANCELLED"),
  Type.Literal("UNKNOWN"),
  Type.Literal("RECONCILING"),
]);

export type RuntimeStatus = Static<typeof RuntimeStatusSchema>;

export const RuntimeActivationReceiptSchema = Type.Object(
  {
    specVersion: Type.Literal("wakeoncue.runtime.activation/v1"),
    externalRunId: Type.String({ minLength: 1 }),
    status: RuntimeStatusSchema,
    acceptedAt: Type.String({ minLength: 1 }),
    receiptDigest: Type.String({ pattern: "^sha256:[a-f0-9]{64}$" }),
  },
  { additionalProperties: false },
);

export type RuntimeActivationReceipt = Static<typeof RuntimeActivationReceiptSchema>;

export interface RuntimeStatusReceipt {
  externalRunId: string;
  status: RuntimeStatus;
  observedAt: string;
  summary?: string;
  evidenceRefs: string[];
}

export interface RuntimeCapabilities {
  preToolInterception: boolean;
  idempotencyQuery: boolean;
  cancellation: boolean;
  statusPolling: boolean;
  callbacks: boolean;
}

export interface RuntimeActivationContext {
  runtimeRunId: string;
  idempotencyKey: string;
  callbackUrl?: string;
}

export interface RuntimeAdapter {
  readonly adapterId: string;
  readonly contractVersion: string;
  readonly capabilities: RuntimeCapabilities;
  activate(
    contract: TaskContract,
    context: RuntimeActivationContext,
  ): Promise<RuntimeActivationReceipt>;
  getStatus(externalRunId: string): Promise<RuntimeStatusReceipt>;
  queryByIdempotencyKey?(idempotencyKey: string): Promise<RuntimeActivationReceipt | undefined>;
  cancel?(externalRunId: string): Promise<RuntimeStatusReceipt>;
}

export class RuntimeTransportError extends Error {
  constructor(
    message: string,
    readonly outcomeUncertain: boolean,
  ) {
    super(message);
    this.name = "RuntimeTransportError";
  }
}

export function activationReceipt(input: {
  externalRunId: string;
  status: RuntimeStatus;
  acceptedAt: string;
  providerReceipt: unknown;
}): RuntimeActivationReceipt {
  return {
    specVersion: "wakeoncue.runtime.activation/v1",
    externalRunId: input.externalRunId,
    status: input.status,
    acceptedAt: input.acceptedAt,
    receiptDigest: `sha256:${sha256(canonicalJson(input.providerReceipt))}`,
  };
}

export async function assertRuntimeConformance(
  adapter: RuntimeAdapter,
  fixture: TaskContract,
): Promise<RuntimeActivationReceipt> {
  if (!adapter.adapterId || !adapter.contractVersion) throw new Error("RUNTIME_IDENTITY_REQUIRED");
  if (!Value.Check(Type.Object({ taskId: Type.String() }), fixture)) {
    throw new Error("TASK_CONTRACT_INVALID");
  }
  const context = {
    runtimeRunId: "run_conformance",
    idempotencyKey: "runtime-conformance-key",
  };
  const first = await adapter.activate(fixture, context);
  const second = await adapter.activate(fixture, context);
  if (!Value.Check(RuntimeActivationReceiptSchema, first)) {
    throw new Error("ACTIVATION_RECEIPT_INVALID");
  }
  if (first.externalRunId !== second.externalRunId) {
    throw new Error("RUNTIME_ACTIVATION_NOT_IDEMPOTENT");
  }
  if (
    !adapter.capabilities.preToolInterception &&
    fixture.capabilityScope.some(isWriteCapability)
  ) {
    throw new Error("WRITE_CAPABILITY_WITHOUT_PRE_TOOL_INTERCEPTION");
  }
  return first;
}

export function isWriteCapability(capability: string): boolean {
  return /(?:\.write|\.send|\.delete|\.create|\.update|payment|purchase|device\.control)$/u.test(
    capability,
  );
}

export function assertRuntimeCapabilityScope(
  capabilities: RuntimeCapabilities,
  scope: readonly string[],
): void {
  if (!capabilities.preToolInterception && scope.some(isWriteCapability)) {
    throw new Error("WRITE_CAPABILITY_REQUIRES_PRE_TOOL_INTERCEPTION");
  }
}
