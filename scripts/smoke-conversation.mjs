import { readFile } from "node:fs/promises";

const apiUrl = process.env["WAKEONCUE_API_URL"] ?? "http://127.0.0.1:4310";
const consoleUrl = process.env["WAKEONCUE_CONSOLE_URL"] ?? "http://127.0.0.1:4173";
const token = process.env["WAKEONCUE_OMI_WEBHOOK_TOKEN"];
if (!token) throw new Error("WAKEONCUE_OMI_WEBHOOK_TOKEN is required");

const payload = await readFile(
  new URL("../packages/source-omi/fixtures/finalized-conversation.v1.json", import.meta.url),
  "utf8",
);
const response = await fetch(`${apiUrl}/v1/sources/omi/omi-smoke`, {
  method: "POST",
  headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
  body: payload,
});
const ingest = await response.json();
if (![200, 202].includes(response.status) || !ingest.event?.eventId) {
  throw new Error(`Omi ingest failed: ${response.status} ${JSON.stringify(ingest)}`);
}

await new Promise((resolve) => setTimeout(resolve, 2_500));
const replayResponse = await fetch(`${apiUrl}/v1/replays`, {
  method: "POST",
  headers: { "content-type": "application/json", "idempotency-key": "conversation-smoke-replay" },
  body: JSON.stringify({ eventIds: [ingest.event.eventId] }),
});
const replay = await replayResponse.json();
const episodeId = replay.replay?.episodes?.[0]?.episodeId;
if (!replayResponse.ok || !episodeId) {
  throw new Error(`Conversation replay failed: ${replayResponse.status} ${JSON.stringify(replay)}`);
}

const timelineResponse = await fetch(`${apiUrl}/v1/episodes/${episodeId}/timeline`);
const timeline = await timelineResponse.json();
const decision = timeline.timeline?.decisions?.at(-1);
if (
  !timelineResponse.ok ||
  decision?.decision?.decision !== "WAKE_AGENT" ||
  decision?.disposition !== "SHADOW_RECORDED"
) {
  throw new Error(
    `Attention timeline failed: ${timelineResponse.status} ${JSON.stringify(timeline)}`,
  );
}

const consoleResponse = await fetch(consoleUrl);
const consoleHtml = await consoleResponse.text();
if (!consoleResponse.ok || !consoleHtml.includes("WakeOnCue Console")) {
  throw new Error(`Console failed: ${consoleResponse.status}`);
}

process.stdout.write(
  `${JSON.stringify(
    {
      inserted: ingest.inserted,
      sourceMode: ingest.mode,
      eventId: ingest.event.eventId,
      episodeId,
      decisionId: decision.decision.decisionId,
      decision: decision.decision.decision,
      reasonCodes: decision.decision.reasonCodes,
      disposition: decision.disposition,
      commitment: decision.signals.commitment,
      deadline: decision.signals.deadline,
      console: "reachable",
      status: "PASS",
    },
    null,
    2,
  )}\n`,
);
