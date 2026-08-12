import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { Value } from "@sinclair/typebox/value";

import { CueEventSchema, type CueEvent } from "@wakeoncue/contracts";
import { replayCueEvents } from "@wakeoncue/core";

import type { ReplayGoldenExpectation } from "./index.ts";

interface ReplayCorpus {
  corpusVersion: string;
  name: string;
  events: CueEvent[];
  expected: ReplayGoldenExpectation;
}

const fixtureArgumentIndex = process.argv.indexOf("--fixture");
const fixturePath = resolve(
  process.cwd(),
  fixtureArgumentIndex >= 0
    ? (process.argv[fixtureArgumentIndex + 1] ?? "")
    : "packages/testing/fixtures/replay-corpus.v1.json",
);
const corpus = JSON.parse(readFileSync(fixturePath, "utf8")) as ReplayCorpus;
if (corpus.corpusVersion !== "wakeoncue.replay-corpus/v1") {
  throw new Error(`Unsupported replay corpus: ${corpus.corpusVersion}`);
}
for (const [index, event] of corpus.events.entries()) {
  if (!Value.Check(CueEventSchema, event)) throw new Error(`Invalid Cue Event at events[${index}]`);
}
const replay = replayCueEvents(corpus.events);
const actual: ReplayGoldenExpectation = {
  eventCount: replay.eventCount,
  duplicateCount: replay.duplicateCount,
  episodeCount: replay.episodes.length,
  deadlineHistory: replay.episodes[0]?.deadlineHistory ?? [],
};
if (JSON.stringify(actual) !== JSON.stringify(corpus.expected)) {
  throw new Error(
    `Golden mismatch\nexpected=${JSON.stringify(corpus.expected)}\nactual=${JSON.stringify(actual)}`,
  );
}
process.stdout.write(
  `${JSON.stringify({ corpus: corpus.name, digest: replay.digest, result: actual, status: "PASS" }, null, 2)}\n`,
);
