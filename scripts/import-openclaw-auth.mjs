import { readFile, unlink } from "node:fs/promises";
import { join, resolve } from "node:path";
import { spawn } from "node:child_process";

if (process.env.WAKEONCUE_OPENCLAW_IMPORT_AUTH !== "1") {
  throw new Error(
    "Set WAKEONCUE_OPENCLAW_IMPORT_AUTH=1 to copy static credentials into the isolated runtime",
  );
}

const root = resolve(import.meta.dirname, "..");
const runtimeRoot = resolve(
  process.env.WAKEONCUE_OPENCLAW_RUNTIME_DIR ?? join(root, ".runtime", "openclaw"),
);
const stateDir = join(runtimeRoot, "state");
const configPath = join(stateDir, "openclaw.json");
const legacyAuthPath = join(stateDir, "agents", "main", "agent", "auth-profiles.json");
const openClawBin = process.env.WAKEONCUE_OPENCLAW_BIN ?? "openclaw";
const nodeBinDir = process.env.WAKEONCUE_OPENCLAW_NODE_BIN_DIR;
const legacyStore = JSON.parse(await readFile(legacyAuthPath, "utf8"));
const profiles = Object.entries(legacyStore.profiles ?? {});
if (profiles.length === 0)
  throw new Error("No static OpenClaw auth profiles are available to import");

async function runOpenClaw(args, secret) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(openClawBin, args, {
      cwd: root,
      env: {
        ...process.env,
        PATH: nodeBinDir ? `${nodeBinDir}:${process.env.PATH ?? ""}` : process.env.PATH,
        OPENCLAW_STATE_DIR: stateDir,
        OPENCLAW_CONFIG_PATH: configPath,
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.once("error", reject);
    child.once("exit", (code) => {
      if (code === 0) resolvePromise({ stdout, stderr });
      else reject(new Error(`OpenClaw auth import failed (${code}): ${stderr || stdout}`));
    });
    child.stdin.end(`${secret}\n`);
  });
}

const imported = [];
for (const [profileId, credential] of profiles) {
  if (
    credential?.type !== "api_key" ||
    typeof credential.provider !== "string" ||
    typeof credential.key !== "string"
  ) {
    throw new Error(`Profile ${profileId} is not a portable static API-key credential`);
  }
  await runOpenClaw(
    [
      "models",
      "auth",
      "--agent",
      "main",
      "paste-api-key",
      "--provider",
      credential.provider,
      "--profile-id",
      profileId,
    ],
    credential.key,
  );
  imported.push({ profileId, provider: credential.provider, type: credential.type });
}

await unlink(legacyAuthPath);
process.stdout.write(`${JSON.stringify({ imported, legacyCopyRemoved: true }, null, 2)}\n`);
