import { beforeEach, describe, expect, test } from "bun:test"
import { db } from "../src/db"
import {
  claimNextJob,
  completeJob,
  enqueueJob,
  failJob,
  queueStats,
  recoverStaleJobs,
} from "../src/queue"

beforeEach(() => {
  db.exec("DELETE FROM jobs")
})

describe("queue", () => {
  test("enqueues a job and deduplicates by delivery id", () => {
    expect(enqueueJob({ deliveryId: "delivery-1", kind: "demo", payload: {} })).toBe(true)
    expect(enqueueJob({ deliveryId: "delivery-1", kind: "demo", payload: {} })).toBe(false)

    expect(queueStats().queued).toBe(1)
  })

  test("claims a job and parses its payload", () => {
    enqueueJob({ deliveryId: "delivery-2", kind: "demo", payload: { hello: "world" } })

    const job = claimNextJob()

    expect(job?.deliveryId).toBe("delivery-2")
    expect(job?.payload).toEqual({ hello: "world" })
    expect(job?.attempts).toBe(1)
    expect(queueStats().running).toBe(1)
  })

  test("completes a job", () => {
    enqueueJob({ deliveryId: "delivery-3", kind: "demo", payload: {} })
    const job = claimNextJob()
    expect(job).not.toBeNull()

    completeJob(job!.id)

    expect(queueStats().done).toBe(1)
  })

  test("fails immediately when max attempts is reached", () => {
    enqueueJob({ deliveryId: "delivery-4", kind: "demo", payload: {}, maxAttempts: 1 })
    const job = claimNextJob()
    expect(job).not.toBeNull()

    failJob(job!.id, new Error("boom"))

    const stats = queueStats()
    expect(stats.failed).toBe(1)
    expect(stats.queued).toBe(0)
  })

  test("re-queues a job with backoff when attempts remain", () => {
    enqueueJob({ deliveryId: "delivery-5", kind: "demo", payload: {}, maxAttempts: 2 })
    const job = claimNextJob()
    expect(job).not.toBeNull()

    failJob(job!.id, new Error("boom"))

    const stats = queueStats()
    expect(stats.queued).toBe(1)
    expect(stats.failed).toBe(0)
  })

  test("recovers stale running jobs", () => {
    enqueueJob({ deliveryId: "delivery-6", kind: "demo", payload: {} })
    const job = claimNextJob()
    expect(job).not.toBeNull()

    db.query("UPDATE jobs SET started_at = ? WHERE id = ?").run(Date.now() - 20 * 60_000, job!.id)

    expect(recoverStaleJobs(10 * 60_000)).toBe(1)
    expect(queueStats().queued).toBe(1)
  })
})
