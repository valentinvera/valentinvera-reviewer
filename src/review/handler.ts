import { config } from "../config"
import { log, errorMessage } from "../logger"
import { canAnchor, indexUnifiedDiff } from "./diff"
import { generateReview } from "./engine"
import {
  buildInlineComment,
  buildRateLimitNotice,
  buildReviewBody,
  buildSummaryComment,
  type RateLimitReason,
} from "./markdown"
import { getInstallationClient, isGitHubStatus, type ReviewGitHubClient } from "./publisher"
import type { Finding } from "./schema"
import {
  clearSummaryCommentId,
  countReviewRuns,
  getLastReviewRunAt,
  getRateLimitNoticeAt,
  getSummaryCommentId,
  hasReviewed,
  markRateLimitNotice,
  markReviewed,
  recordReviewRun,
  setSummaryCommentId,
  type ReviewRunKind,
} from "./store"

export interface ReviewJobPayload {
  installationId: number
  repo: string
  prNumber: number
  /** Empty/omitted for manual `/review`; resolved from the current PR head. */
  headSha?: string
  action: string
  sender?: string
  /** Manual commands bypass the already-reviewed check for the same SHA. */
  force?: boolean
}

export interface ReviewJobDeps {
  getClient?: (installationId: number) => Promise<ReviewGitHubClient>
  generateReview?: typeof generateReview
}

const ACTION_LABEL: Record<string, string> = {
  opened: "PR abierto",
  synchronize: "nuevo push",
  reopened: "PR reabierto",
  ready_for_review: "listo para review",
  manual: "manual",
}

const RATE_LIMIT_WINDOW_MS = 24 * 60 * 60 * 1000

function rateLimitReason(input: {
  repo: string
  prNumber: number
  kind: ReviewRunKind
  now: number
}): RateLimitReason | null {
  const { repo, prNumber, kind, now } = input
  const since = now - RATE_LIMIT_WINDOW_MS

  if (kind === "manual" && config.reviewManualCooldownSeconds > 0) {
    const previous = getLastReviewRunAt(repo, prNumber, "manual")
    if (previous !== null && now - previous < config.reviewManualCooldownSeconds * 1000) {
      return "manual_cooldown"
    }
  }

  if (kind === "auto" && config.reviewAutoMaxPerPr24h > 0) {
    const count = countReviewRuns({ repo, prNumber, kind, since })
    if (count >= config.reviewAutoMaxPerPr24h) return "auto_per_pr_24h"
  }

  if (kind === "manual" && config.reviewManualMaxPerPr24h > 0) {
    const count = countReviewRuns({ repo, prNumber, kind, since })
    if (count >= config.reviewManualMaxPerPr24h) return "manual_per_pr_24h"
  }

  if (config.reviewGlobalMax24h > 0) {
    const count = countReviewRuns({ since })
    if (count >= config.reviewGlobalMax24h) return "global_24h"
  }

  return null
}

async function postRateLimitNotice(
  client: ReviewGitHubClient,
  repo: string,
  prNumber: number,
  reason: RateLimitReason,
  now: number,
): Promise<void> {
  const postedAt = getRateLimitNoticeAt(repo, prNumber)
  if (postedAt !== null && now - postedAt < RATE_LIMIT_WINDOW_MS) return

  try {
    await client.createIssueComment(repo, prNumber, buildRateLimitNotice(reason))
    markRateLimitNotice(repo, prNumber, now)
  } catch (error) {
    log.warn("review.rate_limit_notice_failed", {
      repo,
      pr: prNumber,
      error: errorMessage(error),
    })
  }
}

function partitionFindings(
  findings: Finding[],
  diff: string,
): { anchored: Finding[]; unanchored: Finding[] } {
  const index = indexUnifiedDiff(diff)
  const anchored: Finding[] = []
  const unanchored: Finding[] = []

  for (const finding of findings) {
    if (canAnchor(index, finding.path, finding.line, finding.side)) {
      anchored.push(finding)
    } else {
      unanchored.push(finding)
    }
  }

  return { anchored, unanchored }
}

async function upsertSummaryComment(
  client: ReviewGitHubClient,
  repo: string,
  prNumber: number,
  body: string,
): Promise<void> {
  const existing = getSummaryCommentId(repo, prNumber)

  if (existing !== null) {
    try {
      await client.updateIssueComment(repo, existing, body)
      return
    } catch (error) {
      if (isGitHubStatus(error, 404)) {
        clearSummaryCommentId(repo, prNumber)
      } else {
        throw error
      }
    }
  }

  const created = await client.createIssueComment(repo, prNumber, body)
  setSummaryCommentId(repo, prNumber, created.id)
}

export async function processReviewJob(
  payload: ReviewJobPayload,
  deps: ReviewJobDeps = {},
): Promise<void> {
  const getClient = deps.getClient ?? getInstallationClient
  const generate = deps.generateReview ?? generateReview

  if (
    payload.headSha &&
    !payload.force &&
    hasReviewed(payload.repo, payload.prNumber, payload.headSha)
  ) {
    log.info("review.skip.already_reviewed", {
      repo: payload.repo,
      pr: payload.prNumber,
      sha: payload.headSha.slice(0, 10),
    })
    return
  }

  const client = await getClient(payload.installationId)
  const pr = await client.getPullRequest(payload.repo, payload.prNumber)

  if (pr.state !== "open" || pr.draft) {
    log.info("review.skip.not_open", {
      repo: payload.repo,
      pr: payload.prNumber,
      state: pr.state,
      draft: pr.draft,
    })
    return
  }

  const headSha = payload.headSha?.trim() || pr.headSha

  if (!payload.force && pr.headSha !== headSha) {
    log.info("review.skip.stale", {
      repo: payload.repo,
      pr: payload.prNumber,
      jobSha: headSha.slice(0, 10),
      currentSha: pr.headSha.slice(0, 10),
    })
    return
  }

  if (!payload.force && hasReviewed(payload.repo, payload.prNumber, headSha)) {
    log.info("review.skip.already_reviewed", {
      repo: payload.repo,
      pr: payload.prNumber,
      sha: headSha.slice(0, 10),
    })
    return
  }

  const diff = await client.getPullRequestDiff(payload.repo, payload.prNumber)
  if (!diff.trim()) {
    log.info("review.skip.empty_diff", { repo: payload.repo, pr: payload.prNumber })
    return
  }

  const kind: ReviewRunKind = payload.force ? "manual" : "auto"
  const now = Date.now()
  const limit = rateLimitReason({
    repo: payload.repo,
    prNumber: payload.prNumber,
    kind,
    now,
  })

  if (limit !== null) {
    log.warn("review.rate_limited", {
      repo: payload.repo,
      pr: payload.prNumber,
      kind,
      limit,
    })

    await postRateLimitNotice(client, payload.repo, payload.prNumber, limit, now)
    return
  }

  recordReviewRun({
    repo: payload.repo,
    prNumber: payload.prNumber,
    kind,
    createdAt: now,
  })

  const generated = await generate({ repo: payload.repo, pr, diff })
  const { anchored, unanchored } = partitionFindings(generated.result.findings, diff)

  const comments = anchored.map((finding) => ({
    path: finding.path,
    line: finding.line,
    side: finding.side,
    body: buildInlineComment(finding),
  }))

  const reviewBody = buildReviewBody({
    result: generated.result,
    headSha,
    model: generated.model,
    unanchored,
    truncated: generated.clipped.truncated,
  })

  let review: { id: number; html_url: string }

  try {
    review = await client.createReview(payload.repo, payload.prNumber, {
      commitId: headSha,
      body: reviewBody,
      comments,
    })
  } catch (error) {
    if (isGitHubStatus(error, 422) || isGitHubStatus(error, 400)) {
      log.warn("review.inline_rejected", {
        repo: payload.repo,
        pr: payload.prNumber,
        error: errorMessage(error),
      })

      review = await client.createReview(payload.repo, payload.prNumber, {
        commitId: headSha,
        body: `${reviewBody}\n\n> ⚠️ Algunos comentarios inline no pudieron anclarse y se omitieron.`,
        comments: [],
      })
    } else {
      throw error
    }
  }

  markReviewed({
    repo: payload.repo,
    prNumber: payload.prNumber,
    headSha,
    reviewId: review.id,
  })

  try {
    await upsertSummaryComment(
      client,
      payload.repo,
      payload.prNumber,
      buildSummaryComment({
        result: generated.result,
        headSha,
        model: generated.model,
        reviewUrl: review.html_url,
        trigger: ACTION_LABEL[payload.action] ?? payload.action,
      }),
    )
  } catch (error) {
    // The review is already published; a failed status comment must not
    // trigger a retry that would duplicate the review.
    log.warn("review.summary_comment_failed", {
      repo: payload.repo,
      pr: payload.prNumber,
      error: errorMessage(error),
    })
  }

  log.info("review.published", {
    repo: payload.repo,
    pr: payload.prNumber,
    sha: headSha.slice(0, 10),
    findings: generated.result.findings.length,
    inline: comments.length,
    unanchored: unanchored.length,
    reviewId: review.id,
    reviewUrl: review.html_url,
    durationMs: generated.durationMs,
  })
}
