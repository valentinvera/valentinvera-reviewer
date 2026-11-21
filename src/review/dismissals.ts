import { config } from "../config"
import { errorMessage, log } from "../logger"
import type { ReviewGitHubClient } from "./publisher"
import { addLearnedDismissal, listLearnedDismissals } from "./store"

export const DISMISSAL_REPLY_RE =
  /\b(not an issue|no es un issue|false positive|not a bug|won'?t fix|no es un bug)\b/i

function parseFindingTitle(body: string): string {
  const match = /^\*\*[^*]+·\s*(.+?)\*\*/.exec(body)
  return (
    match?.[1]?.trim() ||
    body
      .split("\n")[0]
      ?.replace(/^\*+|\*+$/g, "")
      .trim() ||
    "Finding"
  )
}

function isBotComment(login: string, body: string): boolean {
  const slug = config.githubAppSlug.toLowerCase()
  const normalized = login.toLowerCase()
  return (
    normalized === slug ||
    normalized === `${slug}[bot]` ||
    normalized.endsWith("[bot]") ||
    /severity ·/i.test(body)
  )
}

export async function learnAndResolveFromReply(input: {
  client: ReviewGitHubClient
  repo: string
  prNumber: number
  replyBody: string
  parentCommentId: number
}): Promise<boolean> {
  if (!DISMISSAL_REPLY_RE.test(input.replyBody)) return false

  const parent = await input.client.getPullRequestReviewComment(input.repo, input.parentCommentId)
  if (!isBotComment(parent.user, parent.body)) return false

  const title = parseFindingTitle(parent.body)
  const existing = listLearnedDismissals(input.repo, 100)
  const already = existing.some(
    (item) =>
      item.sourceCommentId === parent.id || (item.path === parent.path && item.title === title),
  )

  if (!already) {
    addLearnedDismissal({
      repo: input.repo,
      path: parent.path,
      title,
      body: parent.body.slice(0, 1_000),
      reason: "reply",
      sourceCommentId: parent.id,
    })
  }

  try {
    const threads = await input.client.listReviewThreads(input.repo, input.prNumber)
    const thread = threads.find((item) => item.comments.some((comment) => comment.id === parent.id))
    if (thread && !thread.isResolved) {
      await input.client.resolveReviewThread(thread.id)
    }
  } catch (error) {
    log.warn("review.dismissal_resolve_failed", {
      repo: input.repo,
      pr: input.prNumber,
      commentId: parent.id,
      error: errorMessage(error),
    })
  }

  log.info("review.dismissal_learned", {
    repo: input.repo,
    pr: input.prNumber,
    commentId: parent.id,
    reason: "reply",
    title,
  })

  return true
}

/**
 * Scans bot threads for 👎 reactions and learns/resolves them.
 */
export async function learnDismissalsFromReactions(input: {
  client: ReviewGitHubClient
  repo: string
  prNumber: number
}): Promise<number> {
  const threads = await input.client.listReviewThreads(input.repo, input.prNumber)
  let learned = 0

  for (const thread of threads) {
    if (thread.isResolved) continue
    const root = thread.comments[0]
    if (!root) continue
    if (!isBotComment(root.author, root.body)) continue

    let reactions: Array<{ content: string; user: string }>
    try {
      reactions = await input.client.listCommentReactions(input.repo, root.id)
    } catch (error) {
      log.warn("review.reaction_fetch_failed", {
        repo: input.repo,
        commentId: root.id,
        error: errorMessage(error),
      })
      continue
    }

    const thumbsDown = reactions.find((reaction) => reaction.content === "-1")
    if (!thumbsDown) continue

    const title = parseFindingTitle(root.body)
    const existing = listLearnedDismissals(input.repo, 100)
    const already = existing.some((item) => item.sourceCommentId === root.id)
    if (!already) {
      addLearnedDismissal({
        repo: input.repo,
        path: root.path,
        title,
        body: root.body.slice(0, 1_000),
        reason: "thumbs_down",
        sourceCommentId: root.id,
      })
    }

    try {
      await input.client.resolveReviewThread(thread.id)
    } catch (error) {
      log.warn("review.dismissal_resolve_failed", {
        repo: input.repo,
        pr: input.prNumber,
        threadId: thread.id,
        error: errorMessage(error),
      })
    }

    learned += 1
  }

  return learned
}
