import { createHash } from "node:crypto";

import type { CueEvent } from "@wakeoncue/contracts";

export type JsonValue =
  null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

function normalizeJson(value: unknown): JsonValue {
  if (value === null || typeof value === "boolean" || typeof value === "string") return value;
  if (typeof value === "number") {
    if (!Number.isFinite(value))
      throw new TypeError("Canonical JSON does not support non-finite numbers");
    return value;
  }
  if (Array.isArray(value)) return value.map(normalizeJson);
  if (typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([, entry]) => entry !== undefined)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, entry]) => [key, normalizeJson(entry)]),
    );
  }
  throw new TypeError(`Canonical JSON does not support ${typeof value}`);
}

export function canonicalJson(value: unknown): string {
  return JSON.stringify(normalizeJson(value));
}

export function sha256(value: string | Uint8Array): string {
  return createHash("sha256").update(value).digest("hex");
}

export function deterministicId(prefix: string, stableKey: string): string {
  return `${prefix}_${sha256(stableKey).slice(0, 26)}`;
}

export interface EpisodeProjection {
  episodeId: string;
  subject: string;
  correlationId: string;
  eventIds: string[];
  sourceIds: string[];
  types: string[];
  latestData: Record<string, unknown>;
  evidenceRefs: string[];
  deadlineHistory: string[];
  retracted: boolean;
  firstOccurredAt: string;
  lastOccurredAt: string;
}

export interface ReplayProjection {
  replayVersion: "wakeoncue.replay/v1";
  eventCount: number;
  duplicateCount: number;
  episodes: EpisodeProjection[];
  digest: string;
}

function eventOrder(left: CueEvent, right: CueEvent): number {
  return (
    left.occurredAt.localeCompare(right.occurredAt) ||
    left.receivedAt.localeCompare(right.receivedAt) ||
    left.eventId.localeCompare(right.eventId)
  );
}

export function replayCueEvents(inputEvents: readonly CueEvent[]): ReplayProjection {
  const uniqueEvents = new Map<string, CueEvent>();
  for (const event of inputEvents) {
    const existing = uniqueEvents.get(event.eventId);
    if (existing && canonicalJson(existing) !== canonicalJson(event)) {
      throw new Error(`Conflicting event payload for ${event.eventId}`);
    }
    uniqueEvents.set(event.eventId, event);
  }

  const groups = new Map<string, CueEvent[]>();
  for (const event of [...uniqueEvents.values()].sort(eventOrder)) {
    const key = `${event.subject}\u0000${event.correlationId}`;
    const group = groups.get(key) ?? [];
    group.push(event);
    groups.set(key, group);
  }

  const episodes = [...groups.values()]
    .map((events): EpisodeProjection => {
      const first = events[0];
      const last = events.at(-1);
      if (!first || !last) throw new Error("Episode cannot be empty");
      const latestData: Record<string, unknown> = {};
      const sourceIds = new Set<string>();
      const types = new Set<string>();
      const evidenceRefs = new Set<string>();
      const deadlineHistory: string[] = [];
      let retracted = false;

      for (const event of events) {
        Object.assign(latestData, event.data);
        sourceIds.add(event.source.sourceId);
        types.add(event.type);
        for (const evidence of event.evidenceRefs) evidenceRefs.add(evidence.uri);
        const deadline = event.data["deadline"];
        if (typeof deadline === "string" && deadlineHistory.at(-1) !== deadline) {
          deadlineHistory.push(deadline);
        }
        if (event.type.endsWith(".retracted") || event.data["retracted"] === true) {
          retracted = true;
        }
      }

      return {
        episodeId: deterministicId("ep", `${first.subject}:${first.correlationId}`),
        subject: first.subject,
        correlationId: first.correlationId,
        eventIds: events.map((event) => event.eventId),
        sourceIds: [...sourceIds].sort(),
        types: [...types].sort(),
        latestData,
        evidenceRefs: [...evidenceRefs].sort(),
        deadlineHistory,
        retracted,
        firstOccurredAt: first.occurredAt,
        lastOccurredAt: last.occurredAt,
      };
    })
    .sort((left, right) => left.episodeId.localeCompare(right.episodeId));

  const replayWithoutDigest = {
    replayVersion: "wakeoncue.replay/v1" as const,
    eventCount: uniqueEvents.size,
    duplicateCount: inputEvents.length - uniqueEvents.size,
    episodes,
  };
  const deterministicProjection = {
    replayVersion: replayWithoutDigest.replayVersion,
    eventCount: replayWithoutDigest.eventCount,
    episodes: replayWithoutDigest.episodes,
  };
  return {
    ...replayWithoutDigest,
    digest: `sha256:${sha256(canonicalJson(deterministicProjection))}`,
  };
}
