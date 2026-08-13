import { describe, expect, it } from "vitest";

import type { TaskContract } from "@wakeoncue/contracts";

import { argumentsDigest, evaluateAuthorization } from "./index.ts";

const contract: TaskContract = {
  contractVersion: "wakeoncue.task/v1",
  taskId: "task_policy",
  subject: "subject-policy",
  goal: "Send the approved quote",
  successCriteria: ["Recipient receives the exact approved file"],
  constraints: [],
  contextRefs: ["fixture://policy"],
  runtime: { adapter: "openclaw", profile: "default" },
  capabilityScope: ["evidence.read", "task.plan"],
  approvalRequiredFor: ["external.send", "calendar.write", "task.write"],
  idempotencyKey: "policy-fixture",
};

describe("Authorization PDP", () => {
  it("allows only registered bounded reads", () => {
    expect(evaluateAuthorization(contract, "read", { path: "fixture://policy" })).toMatchObject({
      decision: "ALLOW",
      reasonCode: "BOUNDED_READ_ALLOWED",
      risk: { sideEffect: "none" },
    });
    expect(evaluateAuthorization(contract, "read", { path: "/etc/passwd" })).toMatchObject({
      decision: "DENY",
      reasonCode: "READ_TARGET_OUT_OF_SCOPE",
    });
    expect(evaluateAuthorization(contract, "memory_search", { query: "quote" })).toMatchObject({
      decision: "DENY",
      reasonCode: "CAPABILITY_OUT_OF_SCOPE",
    });
    expect(evaluateAuthorization(contract, "exec", { command: "curl example.com" })).toMatchObject({
      decision: "DENY",
      reasonCode: "UNKNOWN_TOOL_DENIED",
    });
  });

  it("requires one-time approval for external sends and denies forbidden operations", () => {
    expect(
      evaluateAuthorization(contract, "file.send", {
        recipient: "contact:zhangsan",
        attachment: "final-quote.pdf",
      }),
    ).toMatchObject({
      decision: "APPROVE_ONCE",
      reasonCode: "EXTERNAL_WRITE_REQUIRES_APPROVAL",
      risk: { destination: "recipient:contact:zhangsan" },
    });
    expect(evaluateAuthorization(contract, "calendar.delete", { id: "event-1" })).toMatchObject({
      decision: "DENY",
      reasonCode: "MVP_FORBIDDEN_OPERATION",
    });
  });

  it("canonicalizes argument digests and redacts secrets from display summaries", () => {
    expect(argumentsDigest({ recipient: "张三", file: "quote.pdf" })).toBe(
      argumentsDigest({ file: "quote.pdf", recipient: "张三" }),
    );
    expect(
      evaluateAuthorization(contract, "message.send", {
        recipient: "张三",
        token: "must-not-display",
      }).displaySummary,
    ).not.toContain("must-not-display");
  });
});
