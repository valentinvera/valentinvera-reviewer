import { Database } from "bun:sqlite"
import { mkdirSync, readdirSync, readFileSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { config } from "./config"
import { log } from "./logger"

mkdirSync(dirname(config.databasePath), { recursive: true })

export const db = new Database(config.databasePath, { create: true, strict: true })

db.exec("PRAGMA journal_mode = WAL;")
db.exec("PRAGMA synchronous = NORMAL;")
db.exec("PRAGMA busy_timeout = 5000;")
db.exec("PRAGMA foreign_keys = ON;")

db.exec(`
  CREATE TABLE IF NOT EXISTS schema_migrations (
    version    TEXT PRIMARY KEY,
    applied_at INTEGER NOT NULL
  );
`)

function applyMigrations(): void {
  const migrationsDir = resolve(import.meta.dir, "db/migrations")
  const files = readdirSync(migrationsDir)
    .filter((file) => file.endsWith(".sql"))
    .sort()

  for (const file of files) {
    const version = file.slice(0, -4)

    const applied = db
      .query<{ version: string }, [string]>(
        "SELECT version FROM schema_migrations WHERE version = ?",
      )
      .get(version)

    if (applied) continue

    const sql = readFileSync(resolve(migrationsDir, file), "utf8")

    const migrate = db.transaction(() => {
      const alreadyApplied = db
        .query<{ version: string }, [string]>(
          "SELECT version FROM schema_migrations WHERE version = ?",
        )
        .get(version)

      if (alreadyApplied) return false

      db.exec(sql)
      db.query<null, [string, number]>(
        "INSERT OR IGNORE INTO schema_migrations (version, applied_at) VALUES (?, ?)",
      ).run(version, Date.now())
      return true
    })

    if (migrate()) {
      log.info("db.migration_applied", { version })
    }
  }
}

applyMigrations()

export function isQueueReady(): boolean {
  const table = db
    .query<{ name: string }, []>(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'jobs'",
    )
    .get()

  return table !== null
}
