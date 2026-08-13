import { mkdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

import type { TaskContract } from "@wakeoncue/contracts";
import { SignedWebhookNotificationAdapter } from "@wakeoncue/notify-sdk";
import { verifyWebhookSignature } from "@wakeoncue/source-webhook";
import { migrateDatabase, openDatabase, SqliteWakeStore } from "@wakeoncue/storage-sqlite";

const secret = "controlled-outcome-notification-secret";
const received: Array<{ idempotencyKey?: string; notificationId?: string }> = [];
const receiver = createServer((request, response) => {
  const chunks: Buffer[] = [];
  request.on("data", (chunk: Buffer) => chunks.push(chunk));
  request.on("end", () => {
    const rawBody = Buffer.concat(chunks).toString("utf8");
    try {
      verifyWebhookSignature({
        rawBody,
        timestamp: request.headers["x-wakeoncue-timestamp"] as string | undefined,
        signature: request.headers["x-wakeoncue-signature"] as string | undefined,
        secret,
        maxClockSkewSeconds: 60,
      });
      const body = JSON.parse(rawBody) as { notificationId?: string };
      received.push({
        ...(request.headers["idempotency-key"]
          ? { idempotencyKey: request.headers["idempotency-key"] as string }
          : {}),
        ...(body.notificationId ? { notificationId: body.notificationId } : {}),
      });
      response.writeHead(200, { "content-type": "application/json" });
      response.end(
        JSON.stringify({
          externalRef: `controlled-receipt-${body.notificationId ?? "unknown"}`,
          acceptedAt: new Date().toISOString(),
          status: "DELIVERED",
        }),
      );
    } catch (error) {
      response.writeHead(401, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: error instanceof Error ? error.message : "invalid" }));
    }
  });
});

await new Promise<void>((resolveListen) => receiver.listen(0, "127.0.0.1", resolveListen));
const address = receiver.address();
if (!address || typeof address === "string") throw new Error("CONTROLLED_RECEIVER_ADDRESS_MISSING");

const databasePath = join(tmpdir(), `wakeoncue-outcome-${process.pid}.sqlite`);
const database = openDatabase(databasePath);
migrateDatabase(database);
const store = new SqliteWakeStore(database);
const occurredAt = new Date().toISOString();
const contract: TaskContract = {
  contractVersion: "wakeoncue.task/v1",
  taskId: "task_outcome_e2e",
  subject: "controlled-local-subject",
  goal: "Verify the controlled local result and notification",
  successCriteria: ["Controlled receiver returns a signed delivery receipt"],
  constraints: ["No real external recipient"],
  contextRefs: ["fixture://outcome-e2e"],
  runtime: { adapter: "controlled", profile: "e2e" },
  capabilityScope: ["evidence.read"],
  approvalRequiredFor: ["external.send"],
  idempotencyKey: "outcome-e2e-task-v1",
};

try {
  database
    .prepare(
      `INSERT INTO episodes(episode_id, subject, correlation_key, state_json, version, updated_at)
       VALUES ('ep_outcome_e2e', ?, 'controlled', '{}', 1, ?)`,
    )
    .run(contract.subject, occurredAt);
  database
    .prepare(
      `INSERT INTO decisions(
         decision_id, episode_id, decision, reason_codes_json, evidence_refs_json,
         strategy_version, record_json, created_at
       ) VALUES ('dec_outcome_e2e', 'ep_outcome_e2e', 'WAKE_AGENT', '[]', '[]', 'e2e/v1', '{}', ?)`,
    )
    .run(occurredAt);
  database
    .prepare(
      `INSERT INTO tasks(task_id, decision_id, idempotency_key, contract_json, status, created_at, updated_at)
       VALUES (?, 'dec_outcome_e2e', ?, ?, 'SUCCEEDED', ?, ?)`,
    )
    .run(
      contract.taskId,
      contract.idempotencyKey,
      JSON.stringify(contract),
      occurredAt,
      occurredAt,
    );
  database
    .prepare(
      `INSERT INTO runtime_runs(
         runtime_run_id, task_id, adapter, external_run_id, agent_run_id,
         idempotency_key, status, last_observed_at, record_json
       ) VALUES ('run_outcome_e2e', ?, 'controlled', 'controlled-run', 'controlled-agent',
                 'outcome-e2e-run-v1', 'SUCCEEDED', ?, '{}')`,
    )
    .run(contract.taskId, occurredAt);

  process.env["WAKEONCUE_NATIVE_NOTIFICATION_GRACE_MS"] = "0";
  const fallbackOutcome = store.recordExternalOutcomeVerification({
    specVersion: "wakeoncue.outcome.external-verification/v1",
    taskId: contract.taskId,
    runtimeRunId: "run_outcome_e2e",
    status: "SUCCEEDED",
    summary: "Controlled receiver verified the result.",
    evidenceRefs: ["receipt:fallback"],
    occurredAt,
    verifier: "controlled-local-verifier",
  });
  const adapter = new SignedWebhookNotificationAdapter({
    url: `http://127.0.0.1:${address.port}/notifications`,
    secret,
  });
  const claim = store.claimNotificationDelivery(
    adapter.channel,
    new Date(Date.now() + 1_000).toISOString(),
  );
  if (!claim) throw new Error("FALLBACK_NOTIFICATION_NOT_CLAIMED");
  const delivery = await adapter.deliver(claim.notification);
  store.completeNotificationDelivery(claim, delivery);

  const nativeOutcome = store.recordExternalOutcomeVerification({
    specVersion: "wakeoncue.outcome.external-verification/v1",
    taskId: contract.taskId,
    runtimeRunId: "run_outcome_e2e",
    status: "SUCCEEDED",
    summary: "Native channel verified the second result.",
    evidenceRefs: ["receipt:native"],
    occurredAt: new Date(Date.now() + 2_000).toISOString(),
    verifier: "controlled-local-verifier",
  });
  store.recordNativeNotificationReceipt({
    specVersion: "wakeoncue.notification.native-receipt/v1",
    receiptId: "native-outcome-e2e-receipt",
    taskId: contract.taskId,
    outcomeId: nativeOutcome.outcomeId,
    runtimeRunId: "run_outcome_e2e",
    channel: "controlled-native",
    status: "DELIVERED",
    occurredAt: new Date(Date.now() + 2_500).toISOString(),
  });
  const duplicateClaim = store.claimNotificationDelivery(
    adapter.channel,
    new Date(Date.now() + 10_000).toISOString(),
  );
  if (duplicateClaim) throw new Error("NATIVE_DELIVERY_DID_NOT_SUPPRESS_FALLBACK");
  if (received.length !== 1)
    throw new Error(`EXPECTED_ONE_FALLBACK_RECEIPT_GOT_${received.length}`);

  const result = {
    status: "PASS",
    mode: "controlled-local-http-receiver",
    node: process.version,
    fallbackOutcomeId: fallbackOutcome.outcomeId,
    nativeOutcomeId: nativeOutcome.outcomeId,
    fallbackDeliveries: received.length,
    duplicateSideEffects: 0,
    nativeSuppressedFallback: true,
    delivery,
    notifications: store.listNotifications(contract.taskId),
  };
  const artifactDirectory = resolve(
    ".runtime/outcome-notification-e2e",
    new Date().toISOString().replaceAll(":", "-").replaceAll(".", "-"),
  );
  mkdirSync(artifactDirectory, { recursive: true });
  const artifactPath = join(artifactDirectory, "result.json");
  writeFileSync(artifactPath, `${JSON.stringify(result, null, 2)}\n`, "utf8");
  process.stdout.write(`${JSON.stringify({ ...result, artifactPath })}\n`);
} finally {
  delete process.env["WAKEONCUE_NATIVE_NOTIFICATION_GRACE_MS"];
  database.close();
  await new Promise<void>((resolveClose, reject) =>
    receiver.close((error) => (error ? reject(error) : resolveClose())),
  );
}
