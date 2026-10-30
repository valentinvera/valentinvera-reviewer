import { config } from "./config"
import { db, isQueueReady } from "./db"
import { handleHealth } from "./health"
import { errorMessage, log } from "./logger"
import { queueStats, recoverStaleJobs } from "./queue"
import { isWorkerRunning, startWorker } from "./worker"
import { handleGitHubWebhook } from "./webhooks/github"
import "./worker/handlers"

const recovered = recoverStaleJobs()
if (recovered > 0) {
  log.warn("queue.recovered", { count: recovered })
}

const worker = config.workerEnabled ? startWorker() : null

function workerStatus(): "running" | "stopped" | "disabled" {
  if (!config.workerEnabled) return "disabled"
  return isWorkerRunning() ? "running" : "stopped"
}

const server = Bun.serve({
  port: config.port,
  hostname: config.hostname,
  maxRequestBodySize: config.maxRequestBodyBytes,

  fetch(request) {
    const url = new URL(request.url)

    if ((request.method === "GET" || request.method === "HEAD") && url.pathname === "/health") {
      return handleHealth(request)
    }

    if (request.method === "POST" && url.pathname === "/webhooks/github") {
      return handleGitHubWebhook(request)
    }

    // TODO: real review handler (`review_pull_request`).
    return Response.json({ error: "not_found" }, { status: 404 })
  },
})

log.info("server.started", {
  url: `http://${config.hostname}:${config.port}`,
  publicUrl: config.publicUrl,
  database: config.databasePath,
  schema: isQueueReady() ? "ready" : "missing",
  worker: workerStatus(),
  queue: queueStats(),
  ai: config.opencodeApiKey ? "configured" : "missing",
  model: config.aiModel,
  githubApp:
    config.githubAppId && config.githubPrivateKey && config.githubWebhookSecret
      ? "configured"
      : "missing",
})

let shuttingDown = false

async function shutdown(signal: string): Promise<void> {
  if (shuttingDown) return
  shuttingDown = true

  log.info("server.stopping", { signal })

  try {
    await worker?.stop()
    server.stop()
    db.close()
  } catch (error) {
    log.error("server.shutdown_failed", { error: errorMessage(error) })
  } finally {
    process.exit(0)
  }
}

process.on("SIGINT", () => void shutdown("SIGINT"))
process.on("SIGTERM", () => void shutdown("SIGTERM"))
