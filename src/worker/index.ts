import { config } from "../config"
import { errorMessage, log } from "../logger"
import { claimNextJob, completeJob, failJob, type Job } from "../queue"

export type JobHandler = (job: Job) => Promise<void>
export type FinalFailureHandler = (job: Job, error: unknown) => Promise<void>

const handlers = new Map<string, JobHandler>()
const finalFailureHandlers = new Map<string, FinalFailureHandler>()
let running = false

/**
 * Registers the function that processes a given job kind.
 * Unregistered kinds fail with a clear error and go through normal retries.
 */
export function registerJobHandler(kind: string, handler: JobHandler): void {
  handlers.set(kind, handler)
}

/** Optional hook when a job permanently fails after exhausting retries. */
export function registerFinalFailureHandler(kind: string, handler: FinalFailureHandler): void {
  finalFailureHandlers.set(kind, handler)
}

export function isWorkerRunning(): boolean {
  return running
}

export function startWorker(): { stop: () => Promise<void> } {
  if (running) throw new Error("Worker is already running")

  running = true
  let stopped = false
  const loops: Promise<void>[] = []

  for (let i = 0; i < config.workerConcurrency; i += 1) {
    loops.push(
      (async () => {
        while (!stopped) {
          let job: Job | null

          try {
            job = claimNextJob()
          } catch (error) {
            log.error("queue.claim_failed", { error: errorMessage(error) })
            await Bun.sleep(config.queuePollMs)
            continue
          }

          if (!job) {
            await Bun.sleep(config.queuePollMs)
            continue
          }

          const handler = handlers.get(job.kind)

          try {
            if (!handler) {
              throw new Error(`No handler registered for job kind: ${job.kind}`)
            }

            await handler(job)
            completeJob(job.id)

            log.info("job.done", {
              id: job.id,
              kind: job.kind,
              attempts: job.attempts,
            })
          } catch (error) {
            log.error("job.failed", {
              id: job.id,
              kind: job.kind,
              attempt: job.attempts,
              maxAttempts: job.maxAttempts,
              error: errorMessage(error),
            })

            const { final } = failJob(job.id, error)
            if (final) {
              const onFinal = finalFailureHandlers.get(job.kind)
              if (onFinal) {
                try {
                  await onFinal(job, error)
                } catch (reportError) {
                  log.error("job.final_failure_handler_failed", {
                    id: job.id,
                    kind: job.kind,
                    error: errorMessage(reportError),
                  })
                }
              }
            }
          }
        }
      })(),
    )
  }

  return {
    stop: async () => {
      if (!running) return
      stopped = true
      await Promise.all(loops)
      running = false
    },
  }
}
