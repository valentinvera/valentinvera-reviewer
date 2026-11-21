import {
  generateText,
  NoObjectGeneratedError,
  NoOutputGeneratedError,
  Output,
  type LanguageModel,
  type LanguageModelUsage,
} from "ai"
import { createReviewModel } from "../ai"
import { config } from "../config"
import { errorMessage, log } from "../logger"
import { chunkDiffBySize, clipDiff, type ClippedDiff } from "./diff"
import {
  buildReviewPrompt,
  type PriorBotThread,
  type ReviewMode,
  type ReviewPullRequest,
} from "./prompt"
import { reviewResultSchema, type Finding, type ReviewResult } from "./schema"
import type { LearnedDismissal } from "./store"

export interface GenerateReviewInput {
  repo: string
  pr: ReviewPullRequest
  diff: string
  /** Override for tests. Defaults to the configured OpenCode Go model. */
  model?: LanguageModel
  mode?: ReviewMode
  comparedFromSha?: string | null
  priorThreads?: PriorBotThread[]
  learnedDismissals?: LearnedDismissal[]
  repoRules?: string | null
  agentsMd?: string | null
  abortSignal?: AbortSignal
  /** Called before each chunk and before returning; throw/return false to stop. */
  shouldContinue?: () => boolean
}

export interface ReviewUsage {
  inputTokens?: number
  outputTokens?: number
  reasoningTokens?: number
  totalTokens?: number
}

export interface GeneratedReview {
  result: ReviewResult
  clipped: ClippedDiff
  model: string
  durationMs: number
  usage: ReviewUsage | undefined
}

export class ReviewSupersededError extends Error {
  constructor(message = "review superseded by a newer push") {
    super(message)
    this.name = "ReviewSupersededError"
  }
}

class EmptyModelResponseError extends Error {
  readonly finishReason: string | undefined

  constructor(finishReason: string | undefined) {
    super(`model returned no text (finishReason=${finishReason ?? "unknown"})`)
    this.name = "EmptyModelResponseError"
    this.finishReason = finishReason
  }
}

interface ModelCallInput {
  repo: string
  pr: ReviewPullRequest
  diff: string
  truncated: boolean
  scope: { index: number; total: number } | null
  model: LanguageModel
  mode: ReviewMode
  comparedFromSha: string | null
  priorThreads: PriorBotThread[]
  learnedDismissals: LearnedDismissal[]
  repoRules: string | null
  agentsMd: string | null
  abortSignal?: AbortSignal
}

function toUsage(usage: LanguageModelUsage | undefined): ReviewUsage | undefined {
  if (!usage) return undefined

  return {
    inputTokens: usage.inputTokens,
    outputTokens: usage.outputTokens,
    reasoningTokens: usage.outputTokenDetails.reasoningTokens,
    totalTokens: usage.totalTokens,
  }
}

function sumUsage(usages: Array<ReviewUsage | undefined>): ReviewUsage | undefined {
  const defined = usages.filter((usage): usage is ReviewUsage => usage !== undefined)
  if (defined.length === 0) return undefined

  return defined.reduce<ReviewUsage>(
    (acc, usage) => ({
      inputTokens: (acc.inputTokens ?? 0) + (usage.inputTokens ?? 0),
      outputTokens: (acc.outputTokens ?? 0) + (usage.outputTokens ?? 0),
      reasoningTokens: (acc.reasoningTokens ?? 0) + (usage.reasoningTokens ?? 0),
      totalTokens: (acc.totalTokens ?? 0) + (usage.totalTokens ?? 0),
    }),
    {},
  )
}

function normalizeFinding(finding: Finding): Finding | null {
  const path = finding.path.trim().replace(/^[ab]\//, "")
  const title = finding.title.trim()
  const body = finding.body.trim()
  const suggestion = finding.suggestion?.trim()

  if (!path || !title || !body) return null

  return {
    ...finding,
    path,
    title,
    body,
    ...(suggestion ? { suggestion } : { suggestion: undefined }),
  }
}

function dedupeFindings(findings: Finding[]): Finding[] {
  const seen = new Set<string>()
  const unique: Finding[] = []

  for (const finding of findings) {
    const key = `${finding.path}:${finding.line}:${finding.side}:${finding.title.toLowerCase()}`
    if (seen.has(key)) continue
    seen.add(key)
    unique.push(finding)
  }

  return unique
}

function normalizeResult(object: ReviewResult): ReviewResult {
  const findings = dedupeFindings(
    object.findings.map(normalizeFinding).filter((finding): finding is Finding => finding !== null),
  ).slice(0, config.reviewMaxFindings)

  const fixedThreadIds = [
    ...new Set((object.fixedThreadIds ?? []).map((id) => id.trim()).filter(Boolean)),
  ]

  return {
    summary: object.summary.trim() || "No significant findings.",
    verdict: object.verdict,
    findings,
    fixedThreadIds,
  }
}

function mergeResults(results: ReviewResult[]): ReviewResult {
  const findings = dedupeFindings(results.flatMap((result) => result.findings)).slice(
    0,
    config.reviewMaxFindings,
  )

  const fixedThreadIds = [...new Set(results.flatMap((result) => result.fixedThreadIds ?? []))]

  const summaries = [...new Set(results.map((result) => result.summary.trim()).filter(Boolean))]
  let summary = summaries.join("\n\n")
  if (summary.length > 2_500) summary = `${summary.slice(0, 2_500).trimEnd()}…`

  const prefix = `Review split into ${results.length} parts because of diff size.`

  return {
    summary: [prefix, summary].join("\n\n").trim(),
    verdict: findings.length > 0 ? "needs_changes" : "looks_good",
    findings,
    fixedThreadIds,
  }
}

function assertContinue(
  shouldContinue: (() => boolean) | undefined,
  abortSignal?: AbortSignal,
): void {
  if (abortSignal?.aborted) throw new ReviewSupersededError()
  if (shouldContinue && !shouldContinue()) throw new ReviewSupersededError()
}

async function callModel(input: ModelCallInput): Promise<{
  result: ReviewResult
  usage: LanguageModelUsage | undefined
}> {
  const { system, prompt } = buildReviewPrompt({
    repo: input.repo,
    pr: input.pr,
    diff: input.diff,
    truncated: input.truncated,
    maxFindings: config.reviewMaxFindings,
    scope: input.scope,
    mode: input.mode,
    comparedFromSha: input.comparedFromSha,
    priorThreads: input.priorThreads,
    learnedDismissals: input.learnedDismissals,
    repoRules: input.repoRules,
    agentsMd: input.agentsMd,
  })

  const timeoutSignal = AbortSignal.timeout(config.aiTimeoutMs)
  const abortSignal = input.abortSignal
    ? AbortSignal.any([input.abortSignal, timeoutSignal])
    : timeoutSignal

  try {
    const generated = await generateText({
      model: input.model,
      output: Output.object({
        schema: reviewResultSchema,
        name: "PullRequestReview",
        description: "Structured code review for a pull request diff.",
      }),
      system,
      prompt,
      temperature: 0.1,
      maxOutputTokens: config.aiMaxOutputTokens,
      maxRetries: 2,
      abortSignal,
    })

    let output: ReviewResult
    try {
      output = generated.output
    } catch (error) {
      if (NoOutputGeneratedError.isInstance(error)) {
        throw new EmptyModelResponseError(generated.finishReason)
      }
      throw error
    }

    return { result: normalizeResult(output), usage: generated.usage }
  } catch (error) {
    if (error instanceof ReviewSupersededError) throw error
    if (error instanceof EmptyModelResponseError) throw error
    if (NoObjectGeneratedError.isInstance(error)) {
      throw new EmptyModelResponseError(error.finishReason ?? undefined)
    }
    if (input.abortSignal?.aborted) throw new ReviewSupersededError()
    throw new Error(`AI review failed: ${errorMessage(error)}`)
  }
}

async function reviewChunks(input: {
  repo: string
  pr: ReviewPullRequest
  chunks: string[]
  model: LanguageModel
  mode: ReviewMode
  comparedFromSha: string | null
  priorThreads: PriorBotThread[]
  learnedDismissals: LearnedDismissal[]
  repoRules: string | null
  agentsMd: string | null
  abortSignal?: AbortSignal
  shouldContinue?: () => boolean
}): Promise<{ result: ReviewResult; usage: ReviewUsage | undefined }> {
  const partials = []

  for (const [index, chunk] of input.chunks.entries()) {
    assertContinue(input.shouldContinue, input.abortSignal)

    log.info("review.chunk_start", {
      index: index + 1,
      total: input.chunks.length,
      chars: chunk.length,
    })

    partials.push(
      await callModel({
        repo: input.repo,
        pr: input.pr,
        diff: chunk,
        truncated: false,
        scope: { index: index + 1, total: input.chunks.length },
        model: input.model,
        mode: input.mode,
        comparedFromSha: input.comparedFromSha,
        priorThreads: input.priorThreads,
        learnedDismissals: input.learnedDismissals,
        repoRules: input.repoRules,
        agentsMd: input.agentsMd,
        abortSignal: input.abortSignal,
      }),
    )

    log.info("review.chunk_done", { index: index + 1, total: input.chunks.length })
  }

  return {
    result: mergeResults(partials.map((partial) => partial.result)),
    usage: sumUsage(partials.map((partial) => toUsage(partial.usage))),
  }
}

export async function generateReview(input: GenerateReviewInput): Promise<GeneratedReview> {
  const clipped = clipDiff(input.diff, config.reviewMaxDiffChars)
  const model = input.model ?? createReviewModel()
  const chunks = chunkDiffBySize(clipped.diff, config.reviewChunkChars)
  const startedAt = performance.now()
  const mode = input.mode ?? "full"
  const comparedFromSha = input.comparedFromSha ?? null
  const priorThreads = input.priorThreads ?? []
  const learnedDismissals = input.learnedDismissals ?? []
  const repoRules = input.repoRules ?? null
  const agentsMd = input.agentsMd ?? null

  let result: ReviewResult
  let usage: ReviewUsage | undefined

  assertContinue(input.shouldContinue, input.abortSignal)

  if (clipped.diff.length > config.reviewChunkChars && chunks.length > 1) {
    log.info("review.chunked", {
      repo: input.repo,
      pr: input.pr.number,
      chunks: chunks.length,
    })

    const chunked = await reviewChunks({
      repo: input.repo,
      pr: input.pr,
      chunks,
      model,
      mode,
      comparedFromSha,
      priorThreads,
      learnedDismissals,
      repoRules,
      agentsMd,
      abortSignal: input.abortSignal,
      shouldContinue: input.shouldContinue,
    })

    result = chunked.result
    usage = chunked.usage
  } else {
    try {
      const single = await callModel({
        repo: input.repo,
        pr: input.pr,
        diff: clipped.diff,
        truncated: clipped.truncated,
        scope: null,
        model,
        mode,
        comparedFromSha,
        priorThreads,
        learnedDismissals,
        repoRules,
        agentsMd,
        abortSignal: input.abortSignal,
      })

      result = single.result
      usage = toUsage(single.usage)
    } catch (error) {
      if (error instanceof ReviewSupersededError) throw error
      if (!(error instanceof EmptyModelResponseError) || chunks.length <= 1) {
        if (error instanceof EmptyModelResponseError) {
          throw new Error(
            [
              "AI review returned no text.",
              `finishReason=${error.finishReason ?? "unknown"}.`,
              "Set AI_REASONING_MODE=low or raise AI_MAX_OUTPUT_TOKENS.",
            ].join(" "),
          )
        }
        throw error
      }

      log.warn("review.fallback_chunked", {
        repo: input.repo,
        pr: input.pr.number,
        chunks: chunks.length,
        finishReason: error.finishReason,
      })

      const chunked = await reviewChunks({
        repo: input.repo,
        pr: input.pr,
        chunks,
        model,
        mode,
        comparedFromSha,
        priorThreads,
        learnedDismissals,
        repoRules,
        agentsMd,
        abortSignal: input.abortSignal,
        shouldContinue: input.shouldContinue,
      })

      result = chunked.result
      usage = chunked.usage
    }
  }

  assertContinue(input.shouldContinue, input.abortSignal)

  const durationMs = Math.round(performance.now() - startedAt)

  log.info("review.generated", {
    repo: input.repo,
    pr: input.pr.number,
    findings: result.findings.length,
    truncated: clipped.truncated,
    durationMs,
    inputTokens: usage?.inputTokens,
    outputTokens: usage?.outputTokens,
    reasoningTokens: usage?.reasoningTokens,
  })

  return {
    result,
    clipped,
    model: config.aiModel,
    durationMs,
    usage,
  }
}
