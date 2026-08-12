import { createHmac } from "node:crypto";

const baseUrl = process.env["WAKEONCUE_API_URL"] ?? "http://127.0.0.1:4310";
const secret = process.env["WAKEONCUE_WEBHOOK_SECRET"];
if (!secret) throw new Error("WAKEONCUE_WEBHOOK_SECRET is required");

const payload = JSON.stringify({
  specVersion: "wakeoncue.source.webhook/v1",
  providerEventId: "smoke-provider-1",
  type: "conversation.commitment.detected",
  subject: "smoke-user",
  occurredAt: "2026-08-12T12:00:00.000Z",
  correlationId: "smoke-conversation-1",
  confidence: 0.98,
  data: { commitment: "周五前发送最终报价", deadline: "2026-08-14" },
  evidenceRefs: [
    {
      uri: "fixture://smoke/conversation/segment-1",
      mediaType: "text/plain",
      classification: "private",
    },
  ],
  privacy: { purpose: ["attention", "task-activation"], retention: "P7D" },
});
const timestamp = Math.floor(Date.now() / 1000);
const signature = `v1=${createHmac("sha256", secret)
  .update(`${timestamp}.${payload}`)
  .digest("hex")}`;
const headers = {
  "content-type": "application/json",
  "idempotency-key": "smoke-webhook-request-1",
  "x-wakeoncue-timestamp": String(timestamp),
  "x-wakeoncue-signature": signature,
};

const responses = [];
for (let attempt = 0; attempt < 10; attempt += 1) {
  const response = await fetch(`${baseUrl}/v1/sources/webhook/smoke-source`, {
    method: "POST",
    headers,
    body: payload,
  });
  const body = await response.json();
  if (![200, 202].includes(response.status)) {
    throw new Error(
      `Webhook attempt ${attempt + 1} failed: ${response.status} ${JSON.stringify(body)}`,
    );
  }
  responses.push(body);
}

const eventIds = new Set(responses.map((response) => response.event?.eventId));
if (eventIds.size !== 1 || eventIds.has(undefined)) {
  throw new Error(`Expected one stable event id, received ${JSON.stringify([...eventIds])}`);
}
const eventId = [...eventIds][0];
await new Promise((resolve) => setTimeout(resolve, 1_500));

const replayResponse = await fetch(`${baseUrl}/v1/replays`, {
  method: "POST",
  headers: { "content-type": "application/json", "idempotency-key": "smoke-replay-1" },
  body: JSON.stringify({ eventIds: [eventId] }),
});
const replayBody = await replayResponse.json();
if (!replayResponse.ok || replayBody.replay?.eventCount !== 1) {
  throw new Error(`Replay failed: ${replayResponse.status} ${JSON.stringify(replayBody)}`);
}
const episodeId = replayBody.replay.episodes?.[0]?.episodeId;
const episodeResponse = await fetch(`${baseUrl}/v1/episodes/${episodeId}`);
const episodeBody = await episodeResponse.json();
if (!episodeResponse.ok || episodeBody.episode?.eventIds?.length !== 1) {
  throw new Error(`Projection failed: ${episodeResponse.status} ${JSON.stringify(episodeBody)}`);
}

process.stdout.write(
  `${JSON.stringify(
    {
      attempts: responses.length,
      inserted: responses.filter((response) => response.inserted === true).length,
      duplicateResponses: responses.filter((response) => response.inserted === false).length,
      eventId,
      episodeId,
      replayDigest: replayBody.replay.digest,
      projectedEventCount: episodeBody.episode.eventIds.length,
      status: "PASS",
    },
    null,
    2,
  )}\n`,
);
