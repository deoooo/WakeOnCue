import { execFileSync } from "node:child_process";
import { describe, expect, it } from "vitest";

describe("replay golden CLI", () => {
  it("matches the versioned corpus", () => {
    const output = execFileSync(
      process.execPath,
      ["node_modules/tsx/dist/cli.mjs", "packages/testing/src/replay-cli.ts"],
      { cwd: process.cwd(), encoding: "utf8" },
    );
    expect(JSON.parse(output)).toMatchObject({
      status: "PASS",
      corpus: "deadline-change-and-duplicate",
    });
  });
});
