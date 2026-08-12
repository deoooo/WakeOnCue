import type { CueEvent } from "@wakeoncue/contracts";

export interface SourceAdapterContext {
  sourceId: string;
  receivedAt: string;
  idempotencyKey?: string;
}

export interface SourceAdapter<Raw> {
  readonly adapterId: string;
  readonly contractVersion: string;
  validate(raw: unknown): raw is Raw;
  validationErrors(raw: unknown): string[];
  ingest(raw: Raw, context: SourceAdapterContext): CueEvent[];
}

export function assertSourceConformance<Raw>(
  adapter: SourceAdapter<Raw>,
  validFixture: unknown,
  invalidFixture: unknown,
  context: SourceAdapterContext,
): CueEvent[] {
  if (!adapter.adapterId || !adapter.contractVersion)
    throw new Error("Adapter identity is required");
  if (!adapter.validate(validFixture)) {
    throw new Error(`Valid fixture rejected: ${adapter.validationErrors(validFixture).join(", ")}`);
  }
  if (adapter.validate(invalidFixture)) throw new Error("Invalid fixture was accepted");
  const first = adapter.ingest(validFixture, context);
  const second = adapter.ingest(validFixture, context);
  if (JSON.stringify(first) !== JSON.stringify(second))
    throw new Error("Adapter mapping is not deterministic");
  if (first.some((event) => event.source.adapter !== adapter.adapterId)) {
    throw new Error("Adapter leaked an inconsistent source identity");
  }
  return first;
}
