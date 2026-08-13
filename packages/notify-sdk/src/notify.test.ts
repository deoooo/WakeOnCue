import { describe, expect, it } from "vitest";

import type { Notification } from "@wakeoncue/contracts";

import { SignedWebhookNotificationAdapter, assertNotificationConformance } from "./index.ts";

const fixture: Notification = {
  specVersion: "wakeoncue.notification/v1",
  notificationId: "notification_fixture",
  taskId: "task_fixture",
  outcomeId: "outcome_fixture",
  channel: "fallback-webhook",
  category: "verified-completion",
  deduplicationKey: "notify:fixture",
  payload: { template: "verified-completion", deepLink: "/tasks/task_fixture" },
  createdAt: "2026-08-13T10:00:00.000Z",
};

describe("Notification SDK", () => {
  it("signs a fixed-template fallback delivery and enforces adapter idempotency", async () => {
    const requests: Array<{
      body: string;
      signature: string | null;
      idempotencyKey: string | null;
    }> = [];
    const adapter = new SignedWebhookNotificationAdapter({
      url: "http://127.0.0.1:9999/notify",
      secret: "test-notification-secret",
      fetch: (_input, init) => {
        const headers = new Headers(init?.headers);
        const body = init?.body;
        requests.push({
          body: typeof body === "string" ? body : "",
          signature: headers.get("x-wakeoncue-signature"),
          idempotencyKey: headers.get("idempotency-key"),
        });
        return Promise.resolve(
          Response.json({
            externalRef: "fallback-receipt-1",
            acceptedAt: "2026-08-13T10:00:01.000Z",
            status: "DELIVERED",
          }),
        );
      },
    });
    const receipt = await assertNotificationConformance(adapter, fixture);
    expect(receipt).toMatchObject({ externalRef: "fallback-receipt-1", status: "DELIVERED" });
    expect(requests).toHaveLength(2);
    expect(requests[0]?.signature).toMatch(/^v1=[a-f0-9]{64}$/u);
    expect(requests[0]?.idempotencyKey).toBe(fixture.deduplicationKey);
    expect(requests[0]?.body).toContain("verified-completion");
  });
});
