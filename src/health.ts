import { isQueueReady } from "./db"
import { isWorkerRunning } from "./worker"

export const SERVICE = "valentinvera-reviewer"

export interface HealthChecks {
  queueReady: () => boolean
  workerRunning: () => boolean
}

const defaultChecks: HealthChecks = {
  queueReady: isQueueReady,
  workerRunning: isWorkerRunning,
}

export function isHealthy(checks: HealthChecks = defaultChecks): boolean {
  return checks.queueReady() && checks.workerRunning()
}

export function handleHealth(request: Request, checks: HealthChecks = defaultChecks): Response {
  const healthy = isHealthy(checks)
  const status = healthy ? 200 : 503

  if (request.method === "HEAD") {
    return new Response(null, { status })
  }

  return Response.json({ ok: healthy, service: SERVICE }, { status })
}
