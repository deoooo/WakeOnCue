import { defineConfig } from "vitest/config";
import { fileURLToPath } from "node:url";

const packageSource = (path: string): string => fileURLToPath(new URL(path, import.meta.url));

export default defineConfig({
  resolve: {
    alias: {
      "@wakeoncue/contracts": packageSource("./packages/contracts/src/index.ts"),
      "@wakeoncue/attention": packageSource("./packages/attention/src/index.ts"),
      "@wakeoncue/core": packageSource("./packages/core/src/index.ts"),
      "@wakeoncue/notify-sdk": packageSource("./packages/notify-sdk/src/index.ts"),
      "@wakeoncue/policy": packageSource("./packages/policy/src/index.ts"),
      "@wakeoncue/runtime-openclaw": packageSource("./packages/runtime-openclaw/src/index.ts"),
      "@wakeoncue/runtime-sdk": packageSource("./packages/runtime-sdk/src/index.ts"),
      "@wakeoncue/runtime-webhook": packageSource("./packages/runtime-webhook/src/index.ts"),
      "@wakeoncue/source-omi": packageSource("./packages/source-omi/src/index.ts"),
      "@wakeoncue/source-sdk": packageSource("./packages/source-sdk/src/index.ts"),
      "@wakeoncue/source-webhook": packageSource("./packages/source-webhook/src/index.ts"),
      "@wakeoncue/storage": packageSource("./packages/storage/src/index.ts"),
      "@wakeoncue/storage-sqlite": packageSource("./packages/storage-sqlite/src/index.ts"),
      "@wakeoncue/testing": packageSource("./packages/testing/src/index.ts"),
    },
  },
  test: {
    coverage: { reporter: ["text", "json-summary", "html"] },
    include: ["apps/**/*.test.ts", "packages/**/*.test.ts"],
    testTimeout: 10_000,
  },
});
