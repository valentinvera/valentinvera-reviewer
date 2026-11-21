import { config } from "../config"
import { errorMessage, log } from "../logger"
import type { ReviewJobPayload } from "./handler"
import { buildFailureComment } from "./markdown"
import { getInstallationClient, isGitHubStatus, type ReviewGitHubClient } from "./publisher"
import {
  clearActiveReview,
  getActiveReview,
  getFailureCommentId,
  setFailureCommentId,
} from "./store"

async function upsertFailureComment(
  client: ReviewGitHubClient,
  repo: string,
  prNumber: number,
  body: string,
): Promise<void> {
  const existing = getFailureCommentId(repo, prNumber)

  if (existing !== null) {
    try {
      await client.updateIssueComment(repo, existing, body)
      return
    } catch (error) {
      if (!isGitHubStatus(error, 404)) throw error
    }
  }

  const created = await client.createIssueComment(repo, prNumber, body)
  setFailureCommentId(repo, prNumber, created.id)
}

/**
 * Called when a review job exhausts its retries. Completes any in-flight check
 * as failure and posts/updates a short PR comment with a `/review` retry hint.
 */
export async function reportFinalReviewFailure(
  payload: ReviewJobPayload,
  error: unknown,
  deps: {
    getClient?: (installationId: number) => Promise<ReviewGitHubClient>
  } = {},
): Promise<void> {
  const getClient = deps.getClient ?? getInstallationClient

  try {
    const client = await getClient(payload.installationId)
    const pr = await client.getPullRequest(payload.repo, payload.prNumber)

    // Still silent for closed/draft auto failures — nothing useful to show.
    if (pr.state !== "open") return
    if (pr.draft && !payload.force) return

    const headSha = payload.headSha?.trim() || pr.headSha
    const active = getActiveReview(payload.repo, payload.prNumber)
    const checkRunId = active?.checkRunId ?? null

    if (checkRunId !== null) {
      try {
        await client.updateCheckRun(payload.repo, checkRunId, {
          status: "completed",
          conclusion: "failure",
          title: "Review failed",
          summary: errorMessage(error).slice(0, 500),
        })
      } catch (checkError) {
        log.warn("review.failure_check_failed", {
          repo: payload.repo,
          pr: payload.prNumber,
          error: errorMessage(checkError),
        })
      }
    } else {
      try {
        await client.createCheckRun(payload.repo, {
          name: config.reviewCheckName,
          headSha,
          status: "completed",
          conclusion: "failure",
          title: "Review failed",
          summary: errorMessage(error).slice(0, 500),
        })
      } catch (checkError) {
        log.warn("review.failure_check_create_failed", {
          repo: payload.repo,
          pr: payload.prNumber,
          error: errorMessage(checkError),
        })
      }
    }

    await upsertFailureComment(
      client,
      payload.repo,
      payload.prNumber,
      buildFailureComment(errorMessage(error)),
    )

    clearActiveReview(payload.repo, payload.prNumber)

    log.error("review.final_failure_reported", {
      repo: payload.repo,
      pr: payload.prNumber,
      sha: headSha.slice(0, 10),
      error: errorMessage(error),
    })
  } catch (reportError) {
    log.error("review.final_failure_report_failed", {
      repo: payload.repo,
      pr: payload.prNumber,
      error: errorMessage(reportError),
      original: errorMessage(error),
    })
  }
}
