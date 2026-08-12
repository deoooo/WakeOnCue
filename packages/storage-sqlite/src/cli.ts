import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

import { migrateDatabase, openDatabase, resolveDatabasePath } from "./index.ts";

const command = process.argv[2];
if (command !== "migrate") {
  process.stderr.write("Usage: pnpm db:migrate\n");
  process.exitCode = 2;
} else {
  const databasePath = resolveDatabasePath();
  mkdirSync(dirname(databasePath), { recursive: true });
  const database = openDatabase(databasePath);
  try {
    const applied = migrateDatabase(database);
    process.stdout.write(
      `${JSON.stringify({ databasePath, applied, status: "ok" }, undefined, 2)}\n`,
    );
  } finally {
    database.close();
  }
}
