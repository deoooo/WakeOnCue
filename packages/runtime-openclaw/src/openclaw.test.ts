import { describe, expect, it } from "vitest";

import type { TaskContract } from "@wakeoncue/contracts";
import { RuntimeTransportError, assertRuntimeConformance } from "@wakeoncue/runtime-sdk";

import { OpenClawRuntimeAdapter, renderOpenClawTaskMessage } from "./index.js";

const fixture: TaskContract = {
  contractVersion: "wakeoncue.task/v1",
  taskId: "task_openclaw_fixture",
  subject: "fixture-user",
  goal: "在截止时间前准备报价草稿",
  successCriteria: ["返回草稿证据引用"],
  constraints: ["不得自行外发"],
  contextRefs: ["fixture://openclaw/task"],
  deadline: "2026-08-14T18:00:00+08:00",
  runtime: { adapter: "openclaw", profile: "wakeoncue" },
  capabilityScope: ["contacts.read", "draft.create"],
  approvalRequiredFor: ["message.send", "file.send"],
  idempotencyKey: "wake:openclaw-fixture:v1",
};

describe("OpenClaw runtime adapter", () => {
  it("activates through the supported hooks/agent endpoint without prescribing tool steps", async () => {
    const requests: Array<{
      url: string;
      body: Record<string, unknown>;
      authorization: string | null;
    }> = [];
    const adapter = new OpenClawRuntimeAdapter({
      baseUrl: "http://127.0.0.1:18791",
      hookToken: "test-hook-token",
      pluginVerified: true,
      fetch: (input, init) => {
        const url = typeof input === "string" || input instanceof URL ? String(input) : input.url;
        if (typeof init?.body !== "string") throw new Error("Expected string request body");
        requests.push({
          url,
          body: JSON.parse(init.body) as Record<string, unknown>,
          authorization: new Headers(init?.headers).get("authorization"),
        });
        return Promise.resolve(
          Response.json({ runId: "openclaw-run-1", acceptedAt: "2026-08-12T10:00:00Z" }),
        );
      },
    });
    const receipt = await assertRuntimeConformance(adapter, fixture);
    expect(receipt.externalRunId).toBe("openclaw-run-1");
    expect(requests).toHaveLength(2);
    expect(requests[0]).toMatchObject({
      url: "http://127.0.0.1:18791/hooks/agent",
      authorization: "Bearer test-hook-token",
      body: {
        deliver: false,
        idempotencyKey: "runtime-conformance-key",
        timeoutSeconds: 120,
        wakeMode: "now",
      },
    });
    const message = String(requests[0]?.body["message"]);
    expect(message).toContain("WAKEONCUE_TASK_CONTEXT:");
    expect(message).toContain("Plan the work yourself");
    expect(message).not.toContain("First call");
  });

  it("refuses write capabilities when the pre-tool plugin is not verified", async () => {
    const adapter = new OpenClawRuntimeAdapter({
      baseUrl: "http://127.0.0.1:18791",
      hookToken: "test-hook-token",
      fetch: () => Promise.resolve(Response.json({ runId: "unexpected" })),
    });
    await expect(
      adapter.activate(
        { ...fixture, capabilityScope: ["message.send"] },
        { runtimeRunId: "run_no_guard", idempotencyKey: "no-guard" },
      ),
    ).rejects.toThrow("WRITE_CAPABILITY_REQUIRES_PRE_TOOL_INTERCEPTION");
  });

  it("marks missing run correlation as outcome-uncertain", async () => {
    const adapter = new OpenClawRuntimeAdapter({
      baseUrl: "http://127.0.0.1:18791",
      hookToken: "test-hook-token",
      pluginVerified: true,
      fetch: () => Promise.resolve(Response.json({ ok: true })),
    });
    try {
      await adapter.activate(fixture, {
        runtimeRunId: "run_missing_correlation",
        idempotencyKey: "missing-correlation",
      });
      throw new Error("Expected activation to fail");
    } catch (error) {
      expect(error).toBeInstanceOf(RuntimeTransportError);
      expect((error as RuntimeTransportError).outcomeUncertain).toBe(true);
    }
  });

  it("renders only the outcome contract and safety boundary", () => {
    const message = renderOpenClawTaskMessage(fixture, {
      runtimeRunId: "run_render",
      idempotencyKey: "render",
      callbackUrl: "http://127.0.0.1:4310/v1/runtime/callbacks/openclaw",
    });
    expect(message).toContain(fixture.goal);
    expect(message).toContain("不得自行外发");
    expect(message).toContain("runtimeRunId");
  });
});
