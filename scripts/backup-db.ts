import { existsSync, mkdirSync, readdirSync, statSync, unlinkSync } from "node:fs"
import { resolve } from "node:path"
import { Database } from "bun:sqlite"
import { config } from "../src/config"
import { log } from "../src/logger"

const backupDir = resolve(process.env.BACKUP_DIR ?? "./backups")
const keep = Math.max(1, Number.parseInt(process.env.BACKUP_KEEP ?? "7", 10) || 7)

if (!existsSync(config.databasePath)) {
  console.error(`Database not found: ${config.databasePath}`)
  process.exit(1)
}

mkdirSync(backupDir, { recursive: true })

const stamp = new Date().toISOString().replace(/[:.]/g, "-")
const destination = resolve(backupDir, `reviewer-${stamp}.db`)

const db = new Database(config.databasePath)

try {
  // Consistent snapshot while the app keeps running (WAL friendly).
  db.exec(`VACUUM INTO '${destination.replaceAll("'", "''")}'`)
} finally {
  db.close()
}

const check = new Database(destination, { readonly: true })
const integrity = check.query<{ integrity_check: string }, []>("PRAGMA integrity_check").get()
check.close()

if (integrity?.integrity_check !== "ok") {
  throw new Error(`Backup integrity check failed: ${integrity?.integrity_check ?? "unknown"}`)
}

const backups = readdirSync(backupDir)
  .filter((file) => file.startsWith("reviewer-") && file.endsWith(".db"))
  .sort()

for (const file of backups.slice(0, Math.max(0, backups.length - keep))) {
  unlinkSync(resolve(backupDir, file))
}

log.info("backup.created", {
  path: destination,
  bytes: statSync(destination).size,
  kept: Math.min(backups.length, keep),
})
