import { createHmac } from "node:crypto";

import type { Notification } from "@wakeoncue/contracts";
import { canonicalJson, sha256 } from "@wakeoncue/core";

export type NotificationDeliveryStatus = "DELIVERED" | "FAILED" | "UNKNOWN";

export interface NotificationDeliveryReceipt {
  externalRef: string;
  status: NotificationDeliveryStatus;
  acceptedAt: string;
  receiptDigest: string;
}

export interface NotificationAdapter {
  readonly adapterId: string;
  readonly channel: string;
  deliver(notification: Notification): Promise<NotificationDeliveryReceipt>;
}

export class NotificationTransportError extends Error {
  constructor(
    message: string,
    readonly outcomeUncertain: boolean,
  ) {
    super(message);
    this.name = "NotificationTransportError";
  }
}

export function notificationReceipt(input: {
  externalRef: string;
  status: NotificationDeliveryStatus;
  acceptedAt: string;
  providerReceipt: unknown;
}): NotificationDeliveryReceipt {
  return {
    externalRef: input.externalRef,
    status: input.status,
    acceptedAt: input.acceptedAt,
    receiptDigest: `sha256:${sha256(canonicalJson(input.providerReceipt))}`,
  };
}

export async function assertNotificationConformance(
  adapter: NotificationAdapter,
  fixture: Notification,
): Promise<NotificationDeliveryReceipt> {
  if (!adapter.adapterId || !adapter.channel) throw new Error("NOTIFICATION_IDENTITY_REQUIRED");
  const first = await adapter.deliver(fixture);
  const second = await adapter.deliver(fixture);
  if (first.externalRef !== second.externalRef) {
    throw new Error("NOTIFICATION_DELIVERY_NOT_IDEMPOTENT");
  }
  return first;
}

export class SignedWebhookNotificationAdapter implements NotificationAdapter {
  readonly adapterId = "signed-webhook";
  readonly channel: string;
  private readonly fetch: typeof fetch;

  constructor(
    private readonly options: {
      url: string;
      secret: string;
      channel?: string;
      timeoutMs?: number;
      fetch?: typeof fetch;
    },
  ) {
    this.channel = options.channel ?? "fallback-webhook";
    this.fetch = options.fetch ?? globalThis.fetch;
  }

  async deliver(notification: Notification): Promise<NotificationDeliveryReceipt> {
    const body = canonicalJson(notification);
    const timestamp = Math.floor(Date.now() / 1_000);
    const signature = `v1=${createHmac("sha256", this.options.secret)
      .update(`${timestamp}.${body}`)
      .digest("hex")}`;
    try {
      const response = await this.fetch(this.options.url, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "idempotency-key": notification.deduplicationKey,
          "x-wakeoncue-timestamp": String(timestamp),
          "x-wakeoncue-signature": signature,
        },
        body,
        signal: AbortSignal.timeout(this.options.timeoutMs ?? 5_000),
      });
      const providerReceipt = (await response.json()) as {
        externalRef?: string;
        acceptedAt?: string;
        status?: NotificationDeliveryStatus;
      };
      if (!response.ok || !providerReceipt.externalRef) {
        throw new NotificationTransportError(
          `Fallback notification rejected with HTTP ${response.status}`,
          response.status >= 500,
        );
      }
      return notificationReceipt({
        externalRef: providerReceipt.externalRef,
        status: providerReceipt.status ?? "DELIVERED",
        acceptedAt: providerReceipt.acceptedAt ?? new Date().toISOString(),
        providerReceipt,
      });
    } catch (error) {
      if (error instanceof NotificationTransportError) throw error;
      throw new NotificationTransportError(
        error instanceof Error ? error.message : "Fallback notification failed",
        true,
      );
    }
  }
}
