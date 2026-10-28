import { beforeEach, describe, expect, test } from "bun:test"
import { db } from "../src/db"
import { getWebhooks } from "../src/github"
import { queueStats } from "../src/queue"
import { handleGitHubWebhook } from "../src/webhooks/github"

const basePayload = {
  action: "opened",
  installation: { id: 99 },
  repository: { full_name: "valentinvera/plata" },
  pull_request: {
    number: 51,
    draft: false,
    head: { sha: "abc123def456" },
  },
  sender: { login: "valentinvera" },
}

function payloadWith(overrides: Record<string, unknown> = {}): string {
  return JSON.stringify({ ...basePayload, ...overrides })
}

async function webhookRequest(input: {
  body: string
  event?: string
  delivery?: string
  signature?: string
}): Promise<Request> {
  const signature = input.signature ?? (await getWebhooks().sign(input.body))

  return new Request("http://localhost/webhooks/github", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-github-event": input.event ?? "pull_request",
      "x-github-delivery": input.delivery ?? "delivery-1",
      "x-hub-signature-256": signature,
    },
    body: input.body,
  })
}

beforeEach(() => {
  db.exec("DELETE FROM jobs")
})

describe("POST /webhooks/github", () => {
  test("enqueues a pull_request.opened job", async () => {
    const body = payloadWith()
    const response = await handleGitHubWebhook(await webhookRequest({ body }))

    expect(response.status).toBe(202)
    expect(queueStats().queued).toBe(1)

    const row = db.query<{ payload: string }, []>("SELECT payload FROM jobs LIMIT 1").get()

    expect(JSON.parse(row!.payload)).toMatchObject({
      installationId: 99,
      repo: "valentinvera/plata",
      prNumber: 51,
      headSha: "abc123def456",
      action: "opened",
      sender: "valentinvera",
    })
  })

  test("deduplicates retries by delivery id", async () => {
    const body = payloadWith()

    expect((await handleGitHubWebhook(await webhookRequest({ body }))).status).toBe(202)
    expect((await handleGitHubWebhook(await webhookRequest({ body }))).status).toBe(202)
    expect(queueStats().queued).toBe(1)
  })

  test("rejects an invalid signature", async () => {
    const body = payloadWith()
    const response = await handleGitHubWebhook(
      await webhookRequest({ body, signature: "sha256=deadbeef" }),
    )

    expect(response.status).toBe(401)
    expect(queueStats().queued).toBe(0)
  })

  test("requires the webhook headers", async () => {
    const body = payloadWith()
    const response = await handleGitHubWebhook(
      new Request("http://localhost/webhooks/github", { method: "POST", body }),
    )

    expect(response.status).toBe(400)
    expect(queueStats().queued).toBe(0)
  })

  test("acknowledges ping", async () => {
    const body = JSON.stringify({ zen: "keep it simple" })
    const response = await handleGitHubWebhook(await webhookRequest({ body, event: "ping" }))

    expect(response.status).toBe(200)
    expect(queueStats().queued).toBe(0)
  })

  test("ignores non pull_request events", async () => {
    const body = JSON.stringify({ ref: "refs/heads/main" })
    const response = await handleGitHubWebhook(await webhookRequest({ body, event: "push" }))

    expect(response.status).toBe(202)
    expect(queueStats().queued).toBe(0)
  })

  test("ignores draft pull requests", async () => {
    const body = payloadWith({
      pull_request: { ...basePayload.pull_request, draft: true },
    })
    const response = await handleGitHubWebhook(await webhookRequest({ body }))

    expect(response.status).toBe(202)
    expect(queueStats().queued).toBe(0)
  })

  test("ignores unhandled pull_request actions", async () => {
    const body = payloadWith({ action: "closed" })
    const response = await handleGitHubWebhook(await webhookRequest({ body }))

    expect(response.status).toBe(202)
    expect(queueStats().queued).toBe(0)
  })

  test("enqueues ready_for_review", async () => {
    const body = payloadWith({ action: "ready_for_review" })
    const response = await handleGitHubWebhook(await webhookRequest({ body }))

    expect(response.status).toBe(202)
    expect(queueStats().queued).toBe(1)
  })
})
