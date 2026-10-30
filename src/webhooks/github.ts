import { config } from "../config"
import { getWebhooks } from "../github"
import { errorMessage, log } from "../logger"
import { enqueueJob } from "../queue"

const HANDLED_ACTIONS = new Set(["opened", "synchronize", "reopened", "ready_for_review"])
const HANDLED_EVENTS = new Set(["pull_request", "issue_comment"])
const ALLOWED_ASSOCIATIONS = new Set(["OWNER", "MEMBER", "COLLABORATOR"])
const REVIEW_COMMAND = /^(?:@[a-z0-9-]+\s+)?\/review$/i

interface PullRequestEventPayload {
  action: string
  installation?: { id: number }
  repository: { full_name: string }
  pull_request: {
    number: number
    draft: boolean
    head: { sha: string }
  }
  sender?: { login: string }
}

interface IssueCommentEventPayload {
  action: string
  installation?: { id: number }
  repository: { full_name: string }
  issue: {
    number: number
    pull_request?: unknown
  }
  comment: {
    body: string
    user: { login: string }
    author_association: string
  }
}

let handlersRegistered = false

function json(body: unknown, status: number): Response {
  return Response.json(body, { status })
}

function registerHandlers(): void {
  if (handlersRegistered) return
  handlersRegistered = true

  getWebhooks().on("pull_request", ({ id, payload }) => {
    const event = payload as unknown as PullRequestEventPayload

    if (!HANDLED_ACTIONS.has(event.action)) return
    if (event.pull_request.draft) return

    const installationId = event.installation?.id
    if (!installationId) {
      log.warn("webhook.missing_installation", {
        delivery: id,
        repo: event.repository.full_name,
        pr: event.pull_request.number,
      })
      return
    }

    const queued = enqueueJob({
      deliveryId: id,
      kind: "review_pull_request",
      payload: {
        installationId,
        repo: event.repository.full_name,
        prNumber: event.pull_request.number,
        headSha: event.pull_request.head.sha,
        action: event.action,
        sender: event.sender?.login ?? "unknown",
      },
    })

    log.info("webhook.enqueued", {
      delivery: id,
      repo: event.repository.full_name,
      pr: event.pull_request.number,
      action: event.action,
      sha: event.pull_request.head.sha.slice(0, 10),
      queued,
    })
  })

  getWebhooks().on("issue_comment", ({ id, payload }) => {
    const event = payload as unknown as IssueCommentEventPayload

    if (event.action !== "created") return
    if (!event.issue.pull_request) return
    if (!REVIEW_COMMAND.test(event.comment.body.trim())) return

    if (!ALLOWED_ASSOCIATIONS.has(event.comment.author_association.toUpperCase())) {
      log.warn("webhook.command_forbidden", {
        delivery: id,
        repo: event.repository.full_name,
        pr: event.issue.number,
        association: event.comment.author_association,
      })
      return
    }

    const installationId = event.installation?.id
    if (!installationId) {
      log.warn("webhook.missing_installation", {
        delivery: id,
        repo: event.repository.full_name,
        pr: event.issue.number,
      })
      return
    }

    const queued = enqueueJob({
      deliveryId: id,
      kind: "review_pull_request",
      payload: {
        installationId,
        repo: event.repository.full_name,
        prNumber: event.issue.number,
        headSha: "",
        action: "manual",
        sender: event.comment.user.login,
        force: true,
      },
    })

    log.info("webhook.command", {
      delivery: id,
      repo: event.repository.full_name,
      pr: event.issue.number,
      sender: event.comment.user.login,
      queued,
    })
  })
}

/**
 * Receives GitHub App webhooks.
 *
 * - Verifies `X-Hub-Signature-256` against the raw body.
 * - `ping` is acknowledged with 200.
 * - `pull_request` (opened/synchronize/reopened/ready_for_review, non-draft)
 *   is enqueued as `review_pull_request` and acknowledged with 202.
 * - `/review` comments on a PR enqueue a forced manual review.
 *
 * The actual review is intentionally not implemented here: the worker owns it.
 */
export async function handleGitHubWebhook(request: Request): Promise<Response> {
  if (!config.githubWebhookSecret) {
    return json({ error: "webhook_not_configured" }, 503)
  }

  const deliveryId = request.headers.get("x-github-delivery")
  const event = request.headers.get("x-github-event")
  const signature = request.headers.get("x-hub-signature-256")

  if (!deliveryId || !event || !signature) {
    return json({ error: "missing_webhook_headers" }, 400)
  }

  const declaredLength = Number.parseInt(request.headers.get("content-length") ?? "", 10)
  if (Number.isFinite(declaredLength) && declaredLength > config.maxRequestBodyBytes) {
    log.warn("webhook.payload_too_large", {
      delivery: deliveryId,
      event,
      contentLength: declaredLength,
      limit: config.maxRequestBodyBytes,
    })
    return json({ error: "payload_too_large" }, 413)
  }

  let payload: string
  try {
    payload = await request.text()
  } catch (error) {
    log.error("webhook.read_failed", { delivery: deliveryId, event, error: errorMessage(error) })
    return json({ error: "invalid_body" }, 400)
  }

  if (Buffer.byteLength(payload) > config.maxRequestBodyBytes) {
    log.warn("webhook.payload_too_large", {
      delivery: deliveryId,
      event,
      size: Buffer.byteLength(payload),
      limit: config.maxRequestBodyBytes,
    })
    return json({ error: "payload_too_large" }, 413)
  }

  if (!payload) {
    return json({ error: "empty_body" }, 400)
  }

  let validSignature = false
  try {
    validSignature = await getWebhooks().verify(payload, signature)
  } catch {
    validSignature = false
  }

  if (!validSignature) {
    log.warn("webhook.invalid_signature", { delivery: deliveryId, event })
    return json({ error: "invalid_signature" }, 401)
  }

  if (event === "ping") {
    return json({ ok: true, pong: true }, 200)
  }

  if (!HANDLED_EVENTS.has(event)) {
    return json({ ok: true, ignored: `event:${event}` }, 202)
  }

  try {
    registerHandlers()
    await getWebhooks().verifyAndReceive({
      id: deliveryId,
      name: event,
      payload,
      signature,
    })
  } catch (error) {
    log.error("webhook.failed", {
      delivery: deliveryId,
      event,
      error: errorMessage(error),
    })
    return json({ error: "webhook_failed" }, 500)
  }

  return json({ ok: true, delivery: deliveryId }, 202)
}
