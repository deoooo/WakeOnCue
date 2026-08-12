import type { CueEvent } from "@wakeoncue/contracts";
import type { AttentionEngine, AttentionEvaluation, SourceMode } from "@wakeoncue/attention";
import type { EpisodeProjection, ReplayProjection } from "@wakeoncue/core";

export interface AppendEventResult {
  event: CueEvent;
  inserted: boolean;
}

export interface IngressErrorRecord {
  errorId: string;
  sourceId: string;
  bodyDigest: string;
  idempotencyKey?: string;
  reasonCode: string;
  details: string[];
  createdAt: string;
}

export interface EventStore {
  appendEvent(event: CueEvent): AppendEventResult;
  getEvent(eventId: string): CueEvent | undefined;
  getEvents(eventIds?: readonly string[]): CueEvent[];
  recordIngressError(record: IngressErrorRecord): void;
  processProjectionOutbox(limit?: number): number;
  getEpisode(episodeId: string): EpisodeProjection | undefined;
  replay(eventIds?: readonly string[]): ReplayProjection;
  getSourceMode(sourceId: string, cueType: string): SourceMode;
  processAttentionOutbox(engine: AttentionEngine, limit?: number): Promise<number>;
  getDecision(decisionId: string): AttentionEvaluation | undefined;
}
