import { config } from "../config"
import { db } from "../db"

export type JobStatus = "queued" | "running" | "done" | "failed"

export interface Job {
  id: number
  deliveryId: string
  kind: string
  payload: unknown
  attempts: number
  maxAttempts: number
}

export interface QueueStats {
  queued: number
  running: number
  done: number
  failed: number
}

interface JobRow {
  id: number
  delivery_id: string
  kind: string
  payload: string
  attempts: number
  max_attempts: number
}

const insertJob = db.query<null, [string, string, string, number, number, number]>(`
  INSERT OR IGNORE INTO jobs (delivery_id, kind, payload, max_attempts, run_after, created_at)
  VALUES (?, ?, ?, ?, ?, ?)
`)

const claimJob = db.transaction((now: number): Job | null => {
  const row = db
    .query<JobRow, [number]>(`
      SELECT id, delivery_id, kind, payload, attempts, max_attempts
      FROM jobs
      WHERE status = 'queued' AND run_after <= ?
      ORDER BY id
      LIMIT 1
    `)
    .get(now)

  if (!row) return null

  const updated = db
    .query<null, [number, number]>(`
      UPDATE jobs
      SET status = 'running', started_at = ?, attempts = attempts + 1
      WHERE id = ? AND status = 'queued'
    `)
    .run(now, row.id)

  if (updated.changes === 0) return null

  let payload: unknown = row.payload
  try {
    payload = JSON.parse(row.payload)
  } catch {
    // Keep the raw string so the handler can decide what to do.
  }

  return {
    id: row.id,
    deliveryId: row.delivery_id,
    kind: row.kind,
    payload,
    attempts: row.attempts + 1,
    maxAttempts: row.max_attempts,
  }
})

/**
 * Enqueues a job. Returns false when the delivery was already enqueued, which
 * makes GitHub webhook retries idempotent (`X-GitHub-Delivery` is unique).
 */
export function enqueueJob(input: {
  deliveryId: string
  kind: string
  payload: unknown
  maxAttempts?: number
  runAfter?: number
}): boolean {
  const result = insertJob.run(
    input.deliveryId,
    input.kind,
    JSON.stringify(input.payload),
    input.maxAttempts ?? config.jobMaxAttempts,
    input.runAfter ?? 0,
    Date.now(),
  )

  return result.changes > 0
}

export function claimNextJob(): Job | null {
  return claimJob(Date.now())
}

export function completeJob(id: number): void {
  db.query<null, [number, number]>(`
    UPDATE jobs
    SET status = 'done', finished_at = ?
    WHERE id = ? AND status = 'running'
  `).run(Date.now(), id)
}

export function failJob(id: number, error: unknown): void {
  const job = db
    .query<{ attempts: number; max_attempts: number }, [number]>(`
      SELECT attempts, max_attempts FROM jobs WHERE id = ?
    `)
    .get(id)

  if (!job) return

  const message = (error instanceof Error ? error.message : String(error)).slice(0, 2_000)

  if (job.attempts >= job.max_attempts) {
    db.query<null, [string, number, number]>(`
      UPDATE jobs
      SET status = 'failed', last_error = ?, finished_at = ?
      WHERE id = ?
    `).run(message, Date.now(), id)
    return
  }

  // Exponential backoff: 5s, 10s, 20s... capped at 5 minutes.
  const delayMs = Math.min(300_000, 5_000 * 2 ** Math.max(0, job.attempts - 1))

  db.query<null, [string, number, number]>(`
    UPDATE jobs
    SET status = 'queued', last_error = ?, run_after = ?
    WHERE id = ?
  `).run(message, Date.now() + delayMs, id)
}

/** Re-queues jobs left in `running` when the process died mid-flight. */
export function recoverStaleJobs(olderThanMs = 10 * 60_000): number {
  const cutoff = Date.now() - olderThanMs

  const result = db
    .query<null, [number, number]>(`
    UPDATE jobs
    SET status = 'queued',
        run_after = ?,
        last_error = COALESCE(last_error, 'recovered after restart')
    WHERE status = 'running' AND (started_at IS NULL OR started_at < ?)
  `)
    .run(Date.now(), cutoff)

  return result.changes
}

export function queueStats(): QueueStats {
  const rows = db
    .query<{ status: JobStatus; count: number }, []>(`
      SELECT status, COUNT(*) AS count FROM jobs GROUP BY status
    `)
    .all()

  const stats: QueueStats = { queued: 0, running: 0, done: 0, failed: 0 }

  for (const row of rows) {
    if (row.status in stats) {
      stats[row.status] = row.count
    }
  }

  return stats
}
