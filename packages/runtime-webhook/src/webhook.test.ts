import { createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";

import type { TaskContract } from "@wakeoncue/contracts";
import { RuntimeTransportError, assertRuntimeConformance } from "@wakeoncue/runtime-sdk";

import { WebhookRuntimeAdapter } from "./index.js";

const fixture: TaskContract = {
  contractVersion: "wakeoncue.task/v1",
  taskId: "task_runtime_webhook",
  subject: "fixture-subject",
  goal: "Prepare an evidence-backed draft",
  successCriteria: ["Return a draft evidence reference"],
  constraints: ["Do not send externally"],
  contextRefs: ["fixture://runtime-webhook/task"],
  runtime: { adapter: "runtime-webhook", profile: "fixture" },
  capabilityScope: ["draft.read"],
  approvalRequiredFor: ["external.send"],
  idempotencyKey: "runtime-webhook-fixture",
};

describe("generic runtime webhook adapter", () => {
  it("signs an outcome-only activation and passes SDK conformance", async () => {
    const requests: Array<{ body: string; headers: Headers }> = [];
    const adapter = new WebhookRuntimeAdapter({
      endpoint: "https://runtime.invalid/activate",
      secret: "runtime-webhook-test-secret",
      fetch: (_input, init) => {
        if (typeof init?.body !== "string") throw new Error("Expected string request body");
        const body = init.body;
        const headers = new Headers(init?.headers);
        requests.push({ body, headers });
        return Promise.resolve(Response.json({ externalRunId: "generic-runtime-run-1" }));
      },
    });
    const receipt = await assertRuntimeConformance(adapter, fixture);
    expect(receipt.externalRunId).toBe("generic-runtime-run-1");
    expect(requests).toHaveLength(2);
    const first = requests[0];
    if (!first) throw new Error("Expected runtime activation request");
    const timestamp = first.headers.get("x-wakeoncue-runtime-timestamp");
    expect(timestamp).toBeTruthy();
    expect(first.headers.get("x-wakeoncue-runtime-signature")).toBe(
      `v1=${createHmac("sha256", "runtime-webhook-test-secret")
        .update(`${timestamp}.${first.body}`)
        .digest("hex")}`,
    );
    expect(JSON.parse(first.body)).toMatchObject({
      specVersion: "wakeoncue.runtime.webhook/v1",
      contract: { goal: fixture.goal },
      runtimeRunId: "run_conformance",
    });
    expect(first.body).not.toContain("toolSteps");
  });

  it("rejects an unknown runtime status instead of casting it into the lifecycle", async () => {
    const adapter = new WebhookRuntimeAdapter({
      endpoint: "https://runtime.invalid/runs",
      secret: "runtime-webhook-test-secret",
      fetch: () => Promise.resolve(Response.json({ status: "MAYBE_DONE" })),
    });
    await expect(adapter.getStatus("generic-run-invalid")).rejects.toBeInstanceOf(
      RuntimeTransportError,
    );
  });
});
