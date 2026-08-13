import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

import { AttentionEngine } from "@wakeoncue/attention";
import {
  NotificationTransportError,
  SignedWebhookNotificationAdapter,
  type NotificationAdapter,
} from "@wakeoncue/notify-sdk";
import { OpenClawRuntimeAdapter } from "@wakeoncue/runtime-openclaw";
import { RuntimeTransportError, type RuntimeAdapter } from "@wakeoncue/runtime-sdk";
import {
  migrateDatabase,
  openDatabase,
  resolveDatabasePath,
  SqliteWakeStore,
} from "@wakeoncue/storage-sqlite";

const databasePath = resolveDatabasePath();
mkdirSync(dirname(databasePath), { recursive: true });
const database = openDatabase(databasePath);
migrateDatabase(database);
const store = new SqliteWakeStore(database);
const attentionEngine = new AttentionEngine();
const runtimeCallbackUrl =
  process.env["WAKEONCUE_RUNTIME_CALLBACK_URL"] ??
  "http://127.0.0.1:4310/v1/runtime/callbacks/openclaw";

function buildRuntimeAdapter(): RuntimeAdapter | undefined {
  if (process.env["WAKEONCUE_RUNTIME_ADAPTER"] !== "openclaw") return undefined;
  const baseUrl = process.env["WAKEONCUE_OPENCLAW_BASE_URL"];
  const hookToken = process.env["WAKEONCUE_OPENCLAW_HOOK_TOKEN"];
  if (!baseUrl || !hookToken) {
    throw new Error("OpenClaw runtime requires WAKEONCUE_OPENCLAW_BASE_URL and hook token");
  }
  return new OpenClawRuntimeAdapter({
    baseUrl,
    hookToken,
    agentId: process.env["WAKEONCUE_OPENCLAW_AGENT_ID"] ?? "main",
    ...(process.env["WAKEONCUE_OPENCLAW_MODEL"]
      ? { model: process.env["WAKEONCUE_OPENCLAW_MODEL"] }
      : {}),
    timeoutMs: Number(process.env["WAKEONCUE_OPENCLAW_ACTIVATION_TIMEOUT_MS"] ?? "15000"),
    agentTimeoutSeconds: Number(process.env["WAKEONCUE_OPENCLAW_AGENT_TIMEOUT_SECONDS"] ?? "120"),
    pluginVerified: process.env["WAKEONCUE_OPENCLAW_PLUGIN_VERIFIED"] === "1",
  });
}

const runtimeAdapter = buildRuntimeAdapter();

function buildNotificationAdapter(): NotificationAdapter | undefined {
  if (process.env["WAKEONCUE_NOTIFICATION_ADAPTER"] !== "signed-webhook") return undefined;
  const url = process.env["WAKEONCUE_NOTIFICATION_WEBHOOK_URL"];
  const secret = process.env["WAKEONCUE_NOTIFICATION_WEBHOOK_SECRET"];
  if (!url || !secret) {
    throw new Error("Signed notification webhook requires URL and secret");
  }
  return new SignedWebhookNotificationAdapter({ url, secret });
}

const notificationAdapter = buildNotificationAdapter();
let polling = false;

const poll = async (): Promise<void> => {
  if (polling) return;
  polling = true;
  try {
    const projections = store.processProjectionOutbox();
    const decisions = await store.processAttentionOutbox(attentionEngine);
    const staleBefore = new Date(
      Date.now() - Number(process.env["WAKEONCUE_RUNTIME_STALE_AFTER_MS"] ?? "60000"),
    ).toISOString();
    const interruptedUnknown = store.markStaleRuntimeActivationsUnknown(staleBefore);
    const callbackStaleBefore = new Date(
      Date.now() - Number(process.env["WAKEONCUE_RUNTIME_CALLBACK_STALE_AFTER_MS"] ?? "300000"),
    ).toISOString();
    const callbackUnknown = store.markStaleRuntimeRunsUnknown(callbackStaleBefore);
    const unknown = interruptedUnknown + callbackUnknown;
    let activations = 0;
    let notifications = 0;
    if (runtimeAdapter) {
      const claim = store.claimWakeActivation(runtimeAdapter.adapterId, runtimeCallbackUrl);
      if (claim) {
        activations = 1;
        try {
          const receipt = await runtimeAdapter.activate(claim.contract, {
            runtimeRunId: claim.runtimeRunId,
            idempotencyKey: claim.idempotencyKey,
            callbackUrl: claim.callbackUrl,
          });
          store.completeWakeActivation(claim, receipt);
        } catch (error) {
          store.failWakeActivation(
            claim,
            error instanceof Error ? error.message : "Runtime activation failed",
            error instanceof RuntimeTransportError ? error.outcomeUncertain : true,
          );
        }
      }
    }
    if (notificationAdapter) {
      const claim = store.claimNotificationDelivery(notificationAdapter.channel);
      if (claim) {
        notifications = 1;
        try {
          const receipt = await notificationAdapter.deliver(claim.notification);
          store.completeNotificationDelivery(claim, receipt);
        } catch (error) {
          store.failNotificationDelivery(
            claim,
            error instanceof Error ? error.message : "Notification delivery failed",
            error instanceof NotificationTransportError ? error.outcomeUncertain : true,
          );
        }
      }
    }
    if (projections > 0 || decisions > 0 || activations > 0 || notifications > 0 || unknown > 0) {
      process.stdout.write(
        `${JSON.stringify({ activations, decisions, notifications, projections, service: "wakeoncue-worker", unknown })}\n`,
      );
    }
  } catch (error) {
    process.stderr.write(
      `${JSON.stringify({ error: error instanceof Error ? error.message : "unknown", service: "wakeoncue-worker" })}\n`,
    );
  } finally {
    polling = false;
  }
};

const interval = setInterval(() => void poll(), 1_000);
process.stdout.write(
  `${JSON.stringify({ databasePath, service: "wakeoncue-worker", status: "ready" })}\n`,
);

const shutdown = (signal: string): void => {
  clearInterval(interval);
  database.close();
  process.stdout.write(
    `${JSON.stringify({ service: "wakeoncue-worker", signal, status: "stopped" })}\n`,
  );
};

process.once("SIGINT", () => shutdown("SIGINT"));
process.once("SIGTERM", () => shutdown("SIGTERM"));
