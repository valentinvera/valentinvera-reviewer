import { log, errorMessage } from "../logger"
import { canAnchor, indexUnifiedDiff } from "./diff"
import { generateReview } from "./engine"
import { buildInlineComment, buildReviewBody, buildSummaryComment } from "./markdown"
import { getInstallationClient, isGitHubStatus, type ReviewGitHubClient } from "./publisher"
import type { Finding } from "./schema"
import {
  clearSummaryCommentId,
  getSummaryCommentId,
  hasReviewed,
  markReviewed,
  setSummaryCommentId,
} from "./store"

export interface ReviewJobPayload {
  installationId: number
  repo: string
  prNumber: number
  headSha: string
  action: string
  sender?: string
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

  if (hasReviewed(payload.repo, payload.prNumber, payload.headSha)) {
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

  if (pr.headSha !== payload.headSha) {
    log.info("review.skip.stale", {
      repo: payload.repo,
      pr: payload.prNumber,
      jobSha: payload.headSha.slice(0, 10),
      currentSha: pr.headSha.slice(0, 10),
    })
    return
  }

  const diff = await client.getPullRequestDiff(payload.repo, payload.prNumber)
  if (!diff.trim()) {
    log.info("review.skip.empty_diff", { repo: payload.repo, pr: payload.prNumber })
    return
  }

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
    headSha: payload.headSha,
    model: generated.model,
    unanchored,
    truncated: generated.clipped.truncated,
  })

  let review: { id: number; html_url: string }

  try {
    review = await client.createReview(payload.repo, payload.prNumber, {
      commitId: payload.headSha,
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
        commitId: payload.headSha,
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
    headSha: payload.headSha,
    reviewId: review.id,
  })

  try {
    await upsertSummaryComment(
      client,
      payload.repo,
      payload.prNumber,
      buildSummaryComment({
        result: generated.result,
        headSha: payload.headSha,
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
    sha: payload.headSha.slice(0, 10),
    findings: generated.result.findings.length,
    inline: comments.length,
    unanchored: unanchored.length,
    reviewId: review.id,
    reviewUrl: review.html_url,
    durationMs: generated.durationMs,
  })
}
