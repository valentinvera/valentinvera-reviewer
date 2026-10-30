import { describe, expect, test } from "bun:test"
import { handleHealth, type HealthChecks } from "../src/health"

function healthRequest(method: "GET" | "HEAD"): Request {
  return new Request("http://localhost/health", { method })
}

function checks(healthy: boolean): HealthChecks {
  return {
    queueReady: () => healthy,
    workerRunning: () => healthy,
  }
}

describe("/health", () => {
  test("GET returns a minimal body when healthy", async () => {
    const response = handleHealth(healthRequest("GET"), checks(true))

    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({
      ok: true,
      service: "valentinvera-reviewer",
    })
  })

  test("GET returns 503 when the worker is not running", async () => {
    const response = handleHealth(healthRequest("GET"), checks(false))

    expect(response.status).toBe(503)
    expect(await response.json()).toEqual({
      ok: false,
      service: "valentinvera-reviewer",
    })
  })

  test("GET returns 503 when the queue schema is missing", async () => {
    const response = handleHealth(healthRequest("GET"), {
      queueReady: () => false,
      workerRunning: () => true,
    })

    expect(response.status).toBe(503)
  })

  test("HEAD returns the same status with an empty body", async () => {
    for (const healthy of [true, false]) {
      const response = handleHealth(healthRequest("HEAD"), checks(healthy))

      expect(response.status).toBe(healthy ? 200 : 503)
      expect(await response.text()).toBe("")
    }
  })
})
