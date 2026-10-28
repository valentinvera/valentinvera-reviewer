import {
  generateObject,
  NoObjectGeneratedError,
  type LanguageModel,
  type LanguageModelUsage,
} from "ai"
import { createReviewModel } from "../ai"
import { config } from "../config"
import { errorMessage, log } from "../logger"
import { chunkDiffBySize, clipDiff, type ClippedDiff } from "./diff"
import { buildReviewPrompt, type ReviewPullRequest } from "./prompt"
import { reviewResultSchema, type Finding, type ReviewResult } from "./schema"

export interface GenerateReviewInput {
  repo: string
  pr: ReviewPullRequest
  diff: string
  /** Override for tests. Defaults to the configured OpenCode Go model. */
  model?: LanguageModel
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

  if (!path || !title || !body) return null

  return { ...finding, path, title, body }
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

  return {
    summary:
      object.summary.trim() ||
      (config.reviewLanguage === "es" ? "Sin observaciones." : "No significant findings."),
    verdict: object.verdict,
    findings,
  }
}

function mergeResults(results: ReviewResult[]): ReviewResult {
  const findings = dedupeFindings(results.flatMap((result) => result.findings)).slice(
    0,
    config.reviewMaxFindings,
  )

  const summaries = [...new Set(results.map((result) => result.summary.trim()).filter(Boolean))]
  let summary = summaries.join("\n\n")
  if (summary.length > 2_500) summary = `${summary.slice(0, 2_500).trimEnd()}…`

  const prefix =
    config.reviewLanguage === "es"
      ? `Revisión dividida en ${results.length} partes por el tamaño del diff.`
      : `Review split into ${results.length} parts because of diff size.`

  return {
    summary: [prefix, summary].join("\n\n").trim(),
    verdict: findings.length > 0 ? "needs_changes" : "looks_good",
    findings,
  }
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
    language: config.reviewLanguage,
    scope: input.scope,
  })

  try {
    const generated = await generateObject({
      model: input.model,
      schema: reviewResultSchema,
      schemaName: "PullRequestReview",
      schemaDescription: "Structured code review for a pull request diff.",
      system,
      prompt,
      temperature: 0.1,
      maxOutputTokens: 12_000,
      maxRetries: 2,
      abortSignal: AbortSignal.timeout(240_000),
    })

    return { result: normalizeResult(generated.object), usage: generated.usage }
  } catch (error) {
    if (error instanceof NoObjectGeneratedError) {
      throw new EmptyModelResponseError(error.finishReason ?? undefined)
    }
    throw new Error(`AI review failed: ${errorMessage(error)}`)
  }
}

async function reviewChunks(input: {
  repo: string
  pr: ReviewPullRequest
  chunks: string[]
  model: LanguageModel
}): Promise<{ result: ReviewResult; usage: ReviewUsage | undefined }> {
  const partials = []

  for (const [index, chunk] of input.chunks.entries()) {
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

  let result: ReviewResult
  let usage: ReviewUsage | undefined

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
      })

      result = single.result
      usage = toUsage(single.usage)
    } catch (error) {
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
      })

      result = chunked.result
      usage = chunked.usage
    }
  }

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
