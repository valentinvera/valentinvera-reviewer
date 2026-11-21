import { randomUUID } from "node:crypto"
import { config } from "../config"
import { log, errorMessage } from "../logger"
import { canAnchor, indexUnifiedDiff } from "./diff"
import { learnDismissalsFromReactions } from "./dismissals"
import { generateReview, ReviewSupersededError } from "./engine"
import {
  buildInlineComment,
  buildMaxRoundsNotice,
  buildRateLimitNotice,
  buildReviewBody,
  buildSummaryComment,
  type RateLimitReason,
} from "./markdown"
import { extractBotThreads, type ReviewMode } from "./prompt"
import {
  getInstallationClient,
  isGitHubStatus,
  type CheckRunConclusion,
  type ReviewGitHubClient,
} from "./publisher"
import type { Finding } from "./schema"
import {
  beginActiveReview,
  clearActiveReview,
  clearFailureCommentId,
  clearSummaryCommentId,
  countReviewRuns,
  getAutoReviewRounds,
  getLastReviewedSha,
  getLastReviewRunAt,
  getMaxRoundsNotifiedAt,
  getRateLimitNoticeAt,
  getSummaryCommentId,
  hasReviewed,
  incrementAutoReviewRounds,
  isActiveReview,
  listLearnedDismissals,
  markMaxRoundsNotified,
  markRateLimitNotice,
  markReviewed,
  recordReviewRun,
  setActiveReviewCheckRunId,
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
  opened: "PR opened",
  synchronize: "New commits pushed",
  reopened: "PR reopened",
  ready_for_review: "Ready for review",
  manual: "/review command",
}

const RATE_LIMIT_WINDOW_MS = 24 * 60 * 60 * 1000
const FULL_REVIEW_ACTIONS = new Set(["opened", "reopened", "ready_for_review", "manual"])

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

async function completeCheck(
  client: ReviewGitHubClient,
  repo: string,
  checkRunId: number | null,
  input: {
    conclusion: CheckRunConclusion
    title: string
    summary: string
  },
): Promise<void> {
  if (checkRunId === null) return

  try {
    await client.updateCheckRun(repo, checkRunId, {
      status: "completed",
      conclusion: input.conclusion,
      title: input.title,
      summary: input.summary,
    })
  } catch (error) {
    log.warn("review.check_complete_failed", {
      repo,
      checkRunId,
      error: errorMessage(error),
    })
  }
}

async function resolveDiff(input: {
  client: ReviewGitHubClient
  repo: string
  prNumber: number
  headSha: string
  action: string
  force: boolean
}): Promise<{ diff: string; mode: ReviewMode; comparedFromSha: string | null }> {
  const lastSha = getLastReviewedSha(input.repo, input.prNumber)
  const preferIncremental =
    !input.force &&
    input.action === "synchronize" &&
    lastSha !== null &&
    lastSha !== input.headSha &&
    !FULL_REVIEW_ACTIONS.has(input.action)

  if (!preferIncremental) {
    return {
      diff: await input.client.getPullRequestDiff(input.repo, input.prNumber),
      mode: "full",
      comparedFromSha: null,
    }
  }

  try {
    const compared = await input.client.compareCommits(input.repo, lastSha!, input.headSha)
    if (compared.status === "diverged" || compared.behindBy > 0 || !compared.diff.trim()) {
      log.info("review.diff_fallback_full", {
        repo: input.repo,
        pr: input.prNumber,
        reason: compared.status === "diverged" || compared.behindBy > 0 ? "force_push" : "empty",
        from: lastSha!.slice(0, 10),
      })
      return {
        diff: await input.client.getPullRequestDiff(input.repo, input.prNumber),
        mode: "full",
        comparedFromSha: null,
      }
    }

    return {
      diff: compared.diff,
      mode: "incremental",
      comparedFromSha: lastSha,
    }
  } catch (error) {
    log.warn("review.compare_failed", {
      repo: input.repo,
      pr: input.prNumber,
      from: lastSha!.slice(0, 10),
      error: errorMessage(error),
    })
    return {
      diff: await input.client.getPullRequestDiff(input.repo, input.prNumber),
      mode: "full",
      comparedFromSha: null,
    }
  }
}

async function loadRepoGuidance(
  client: ReviewGitHubClient,
  repo: string,
  baseSha: string,
): Promise<{ repoRules: string | null; agentsMd: string | null }> {
  const [repoRules, agentsMd] = await Promise.all([
    client.getFileContent(repo, ".reviewer/rules.md", baseSha),
    client.getFileContent(repo, "AGENTS.md", baseSha),
  ])
  return { repoRules, agentsMd }
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

  if (pr.state !== "open") {
    log.info("review.skip.not_open", {
      repo: payload.repo,
      pr: payload.prNumber,
      state: pr.state,
      draft: pr.draft,
    })
    return
  }

  // Auto reviews skip drafts silently (no comment, no check). Explicit `/review`
  // (force) still runs on drafts.
  if (pr.draft && !payload.force) {
    log.info("review.skip.draft", {
      repo: payload.repo,
      pr: payload.prNumber,
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

  const kind: ReviewRunKind = payload.force ? "manual" : "auto"
  const now = Date.now()

  if (kind === "auto" && config.reviewAutoMaxRounds > 0) {
    const rounds = getAutoReviewRounds(payload.repo, payload.prNumber)
    if (rounds >= config.reviewAutoMaxRounds) {
      if (getMaxRoundsNotifiedAt(payload.repo, payload.prNumber) === null) {
        try {
          await client.createIssueComment(
            payload.repo,
            payload.prNumber,
            buildMaxRoundsNotice(config.reviewAutoMaxRounds),
          )
          markMaxRoundsNotified(payload.repo, payload.prNumber, now)
        } catch (error) {
          log.warn("review.max_rounds_notice_failed", {
            repo: payload.repo,
            pr: payload.prNumber,
            error: errorMessage(error),
          })
        }
      }

      log.info("review.skip.max_rounds", {
        repo: payload.repo,
        pr: payload.prNumber,
        rounds,
        max: config.reviewAutoMaxRounds,
      })
      return
    }
  }

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

  const generationId = randomUUID()
  const abortController = new AbortController()
  beginActiveReview({
    repo: payload.repo,
    prNumber: payload.prNumber,
    generationId,
    headSha,
  })

  let checkRunId: number | null = null

  const stillCurrent = (): boolean => {
    if (!isActiveReview(payload.repo, payload.prNumber, generationId)) {
      abortController.abort()
      return false
    }
    return true
  }

  try {
    try {
      const check = await client.createCheckRun(payload.repo, {
        name: config.reviewCheckName,
        headSha,
        status: "in_progress",
        title: "Review in progress",
        summary: "Automated pull request review is running.",
      })
      checkRunId = check.id
      setActiveReviewCheckRunId(payload.repo, payload.prNumber, check.id)
    } catch (error) {
      log.warn("review.check_start_failed", {
        repo: payload.repo,
        pr: payload.prNumber,
        error: errorMessage(error),
      })
    }

    if (!stillCurrent()) {
      await completeCheck(client, payload.repo, checkRunId, {
        conclusion: "cancelled",
        title: "Review superseded",
        summary: "A newer push replaced this review before it finished.",
      })
      return
    }

    try {
      await learnDismissalsFromReactions({
        client,
        repo: payload.repo,
        prNumber: payload.prNumber,
      })
    } catch (error) {
      log.warn("review.reaction_scan_failed", {
        repo: payload.repo,
        pr: payload.prNumber,
        error: errorMessage(error),
      })
    }

    const { diff, mode, comparedFromSha } = await resolveDiff({
      client,
      repo: payload.repo,
      prNumber: payload.prNumber,
      headSha,
      action: payload.action,
      force: Boolean(payload.force),
    })

    if (!diff.trim()) {
      log.info("review.skip.empty_diff", { repo: payload.repo, pr: payload.prNumber })
      await completeCheck(client, payload.repo, checkRunId, {
        conclusion: "success",
        title: "No diff to review",
        summary: "The pull request has an empty diff.",
      })
      clearActiveReview(payload.repo, payload.prNumber, generationId)
      return
    }

    if (!stillCurrent()) {
      await completeCheck(client, payload.repo, checkRunId, {
        conclusion: "cancelled",
        title: "Review superseded",
        summary: "A newer push replaced this review before it finished.",
      })
      return
    }

    const [threads, guidance] = await Promise.all([
      client.listReviewThreads(payload.repo, payload.prNumber).catch((error) => {
        log.warn("review.threads_fetch_failed", {
          repo: payload.repo,
          pr: payload.prNumber,
          error: errorMessage(error),
        })
        return []
      }),
      loadRepoGuidance(client, payload.repo, pr.baseSha),
    ])

    const priorThreads = extractBotThreads(threads, [
      config.githubAppSlug,
      `${config.githubAppSlug}[bot]`,
    ])
    const learnedDismissals = listLearnedDismissals(payload.repo)

    const generated = await generate({
      repo: payload.repo,
      pr,
      diff,
      mode,
      comparedFromSha,
      priorThreads,
      learnedDismissals,
      repoRules: guidance.repoRules,
      agentsMd: guidance.agentsMd,
      abortSignal: abortController.signal,
      shouldContinue: stillCurrent,
    })

    if (!stillCurrent()) {
      await completeCheck(client, payload.repo, checkRunId, {
        conclusion: "cancelled",
        title: "Review superseded",
        summary: "A newer push replaced this review before publishing.",
      })
      return
    }

    const trigger = ACTION_LABEL[payload.action] ?? payload.action
    const fixedIds = new Set(generated.result.fixedThreadIds ?? [])
    let resolvedCount = 0

    for (const threadId of fixedIds) {
      try {
        await client.resolveReviewThread(threadId)
        resolvedCount += 1
      } catch (error) {
        log.warn("review.resolve_thread_failed", {
          repo: payload.repo,
          pr: payload.prNumber,
          threadId,
          error: errorMessage(error),
        })
      }
    }

    const findingsCount = generated.result.findings.length

    if (findingsCount === 0) {
      await upsertSummaryComment(
        client,
        payload.repo,
        payload.prNumber,
        buildSummaryComment({
          findingsCount,
          headSha,
          model: generated.model,
          reviewUrl: null,
          trigger,
          truncated: generated.clipped.truncated,
          incremental: mode === "incremental",
          resolvedCount,
        }),
      )

      markReviewed({
        repo: payload.repo,
        prNumber: payload.prNumber,
        headSha,
        reviewId: null,
      })
      recordReviewRun({
        repo: payload.repo,
        prNumber: payload.prNumber,
        kind,
        createdAt: Date.now(),
      })
      if (kind === "auto") incrementAutoReviewRounds(payload.repo, payload.prNumber)
      clearFailureCommentId(payload.repo, payload.prNumber)

      await completeCheck(client, payload.repo, checkRunId, {
        conclusion: "success",
        title: mode === "incremental" ? "No new issues" : "No issues found",
        summary:
          mode === "incremental"
            ? "Incremental review finished with no new findings."
            : "Review finished with no findings.",
      })

      clearActiveReview(payload.repo, payload.prNumber, generationId)

      log.info("review.published", {
        repo: payload.repo,
        pr: payload.prNumber,
        sha: headSha.slice(0, 10),
        findings: 0,
        reviewId: null,
        mode,
        durationMs: generated.durationMs,
      })
      return
    }

    const { anchored, unanchored } = partitionFindings(generated.result.findings, diff)

    const comments = anchored.map((finding) => ({
      path: finding.path,
      line: finding.line,
      side: finding.side,
      body: buildInlineComment(finding),
      ...(finding.startLine !== undefined && finding.startLine < finding.line
        ? { startLine: finding.startLine }
        : {}),
    }))

    const reviewBody = buildReviewBody({
      findingsCount,
      headSha,
      model: generated.model,
      unanchored,
      truncated: generated.clipped.truncated,
      incremental: mode === "incremental",
    })

    if (!stillCurrent()) {
      await completeCheck(client, payload.repo, checkRunId, {
        conclusion: "cancelled",
        title: "Review superseded",
        summary: "A newer push replaced this review before publishing.",
      })
      return
    }

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
          body: `${reviewBody}\n\n> ⚠️ Some inline comments could not be anchored to the diff and were omitted.`,
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
    recordReviewRun({
      repo: payload.repo,
      prNumber: payload.prNumber,
      kind,
      createdAt: Date.now(),
    })
    if (kind === "auto") incrementAutoReviewRounds(payload.repo, payload.prNumber)
    clearFailureCommentId(payload.repo, payload.prNumber)

    try {
      await upsertSummaryComment(
        client,
        payload.repo,
        payload.prNumber,
        buildSummaryComment({
          findingsCount,
          headSha,
          model: generated.model,
          reviewUrl: review.html_url,
          trigger,
          truncated: generated.clipped.truncated,
          incremental: mode === "incremental",
          resolvedCount,
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

    await completeCheck(client, payload.repo, checkRunId, {
      conclusion: "neutral",
      title: `${findingsCount} finding${findingsCount === 1 ? "" : "s"}`,
      summary: `Published ${findingsCount} review finding${findingsCount === 1 ? "" : "s"}.`,
    })

    clearActiveReview(payload.repo, payload.prNumber, generationId)

    log.info("review.published", {
      repo: payload.repo,
      pr: payload.prNumber,
      sha: headSha.slice(0, 10),
      findings: findingsCount,
      inline: comments.length,
      unanchored: unanchored.length,
      reviewId: review.id,
      reviewUrl: review.html_url,
      mode,
      durationMs: generated.durationMs,
    })
  } catch (error) {
    if (error instanceof ReviewSupersededError) {
      await completeCheck(client, payload.repo, checkRunId, {
        conclusion: "cancelled",
        title: "Review superseded",
        summary: "A newer push replaced this review before it finished.",
      })
      clearActiveReview(payload.repo, payload.prNumber, generationId)
      log.info("review.superseded", {
        repo: payload.repo,
        pr: payload.prNumber,
        sha: headSha.slice(0, 10),
      })
      return
    }

    await completeCheck(client, payload.repo, checkRunId, {
      conclusion: "failure",
      title: "Review failed",
      summary: errorMessage(error).slice(0, 500),
    })
    clearActiveReview(payload.repo, payload.prNumber, generationId)
    throw error
  }
}
