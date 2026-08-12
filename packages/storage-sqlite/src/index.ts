import Database from "better-sqlite3";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const packageDirectory = dirname(fileURLToPath(import.meta.url));

export function resolveDatabasePath(): string {
  const configuredPath = process.env["WAKEONCUE_DATABASE_PATH"] ?? "./data/wakeoncue.sqlite";
  return configuredPath === ":memory:" ? configuredPath : resolve(process.cwd(), configuredPath);
}

export function openDatabase(databasePath = resolveDatabasePath()): Database.Database {
  const database = new Database(databasePath);
  database.pragma("journal_mode = WAL");
  database.pragma("foreign_keys = ON");
  database.pragma("busy_timeout = 5000");
  return database;
}

export function migrateDatabase(database: Database.Database): string[] {
  database.exec(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version TEXT PRIMARY KEY,
      applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    );
  `);

  const migrationDirectory = resolve(packageDirectory, "migrations");
  const migrations = readdirSync(migrationDirectory)
    .filter((file) => file.endsWith(".sql"))
    .sort();
  const alreadyApplied = database.prepare("SELECT 1 FROM schema_migrations WHERE version = ?");
  const recordMigration = database.prepare("INSERT INTO schema_migrations(version) VALUES (?)");
  const applied: string[] = [];

  for (const migration of migrations) {
    if (alreadyApplied.get(migration)) continue;
    const sql = readFileSync(resolve(migrationDirectory, migration), "utf8");
    database.transaction(() => {
      database.exec(sql);
      recordMigration.run(migration);
    })();
    applied.push(migration);
  }

  return applied;
}
