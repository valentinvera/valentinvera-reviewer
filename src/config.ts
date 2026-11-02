import { readFileSync } from "node:fs"
import { resolve } from "node:path"

export type LogLevel = "debug" | "info" | "warn" | "error"
export type ReasoningMode = "off" | "low" | "high" | "max"

export interface Config {
  /** HTTP server */
  port: number
  hostname: string
  publicUrl: string
  databasePath: string
  logLevel: LogLevel
  maxRequestBodyBytes: number

  /** GitHub App */
  githubAppId: string | undefined
  githubAppSlug: string
  githubPrivateKey: string | undefined
  githubWebhookSecret: string | undefined
  githubApiUrl: string
  /** Optional PAT for local dry-runs and scripts. */
  githubToken: string | undefined

  /** AI provider (OpenCode Go, OpenAI-compatible) */
  opencodeApiKey: string | undefined
  aiBaseUrl: string
  aiModel: string
  aiReasoningMode: ReasoningMode
  /** Output budget per model call. Reasoning tokens count against it. */
  aiMaxOutputTokens: number
  /** Wall-clock deadline for one model call, retries included. */
  aiTimeoutMs: number
  /** OpenCode Go requires a stable session id for routing. */
  aiSessionId: string

  /** Queue / worker */
  queuePollMs: number
  jobMaxAttempts: number
  workerConcurrency: number
  workerEnabled: boolean

  /** Review */
  reviewMaxDiffChars: number
  reviewMaxFindings: number
  reviewChunkChars: number
  /** Rate limits. A value of 0 disables the corresponding limit. */
  reviewAutoMaxPerPr24h: number
  reviewManualCooldownSeconds: number
  reviewManualMaxPerPr24h: number
  reviewGlobalMax24h: number
  /** Lowercased PR author logins whose PRs are never auto-reviewed. */
  reviewSkipAuthors: string[]
}

/**
 * DeepSeek V4.1 Flash on OpenCode Go documents a 384k output limit. Reasoning
 * tokens share this budget, so keep plenty of headroom for the final JSON.
 */
export const DEFAULT_AI_MAX_OUTPUT_TOKENS = 32_000
/** Documented max output of DeepSeek V4.1 Flash; larger values get a 400. */
export const AI_MAX_OUTPUT_TOKENS_CAP = 384_000

/**
 * The model streams ~200 output tokens/s, so a chunk that spends a full 64k
 * budget needs ~320s (a ~33k chunk took ~233s). 10 minutes leaves ~2x headroom.
 */
export const DEFAULT_AI_TIMEOUT_MS = 600_000

export const DEFAULT_REVIEW_SKIP_AUTHORS = [
  "dependabot[bot]",
  "renovate[bot]",
  "snyk-bot",
  "pre-commit-ci[bot]",
  "imgbot[bot]",
  "allcontributors[bot]",
  "release-please[bot]",
] as const

function str(value: string | undefined): string | undefined {
  const trimmed = value?.trim()
  return trimmed ? trimmed : undefined
}

function int(value: string | undefined, fallback: number): number {
  const parsed = Number.parseInt(value ?? "", 10)
  return Number.isFinite(parsed) ? parsed : fallback
}

function positiveInt(value: string | undefined, fallback: number): number {
  const parsed = int(value, fallback)
  return parsed > 0 ? parsed : fallback
}

function oneOf<T extends string>(value: string | undefined, allowed: readonly T[], fallback: T): T {
  const normalized = value?.trim().toLowerCase()
  return allowed.includes(normalized as T) ? (normalized as T) : fallback
}

function bool(value: string | undefined, fallback: boolean): boolean {
  if (value === undefined) return fallback
  return ["1", "true", "yes", "on"].includes(value.trim().toLowerCase())
}

function list(value: string | undefined, fallback: readonly string[]): string[] {
  const items = value === undefined ? fallback : value.split(",")
  return [...new Set(items.map((item) => item.trim().toLowerCase()).filter(Boolean))]
}

function loadPrivateKey(inline: string | undefined, path: string | undefined): string | undefined {
  if (inline) {
    // Supports single-line env vars with escaped newlines.
    return inline.includes("\\n") ? inline.replaceAll("\\n", "\n") : inline
  }

  if (path) {
    try {
      return readFileSync(resolve(path), "utf8")
    } catch (error) {
      if ((error as { code?: string }).code === "ENOENT") {
        // Keep the server bootable before the GitHub App exists.
        console.warn(`[config] GITHUB_PRIVATE_KEY_PATH not found: ${path}`)
        return undefined
      }
      throw error
    }
  }

  return undefined
}

export function loadConfig(env: Record<string, string | undefined> = process.env): Config {
  return {
    port: int(env.PORT, 3000),
    hostname: str(env.HOST) ?? "0.0.0.0",
    publicUrl: str(env.PUBLIC_URL) ?? "http://localhost:3000",
    databasePath: str(env.DATABASE_PATH) ?? "./data/reviewer.db",
    logLevel: oneOf(env.LOG_LEVEL, ["debug", "info", "warn", "error"] as const, "info"),
    maxRequestBodyBytes: int(env.MAX_REQUEST_BODY_BYTES, 10 * 1024 * 1024),

    githubAppId: str(env.GITHUB_APP_ID),
    githubAppSlug: str(env.GITHUB_APP_SLUG) ?? "valentinvera-reviewer",
    githubPrivateKey: loadPrivateKey(env.GITHUB_PRIVATE_KEY, env.GITHUB_PRIVATE_KEY_PATH),
    githubWebhookSecret: str(env.GITHUB_WEBHOOK_SECRET),
    githubApiUrl: str(env.GITHUB_API_URL) ?? "https://api.github.com",
    githubToken: str(env.GITHUB_TOKEN),

    opencodeApiKey: str(env.OPENCODE_API_KEY),
    aiBaseUrl: str(env.AI_BASE_URL) ?? "https://opencode.ai/inference/go/openai/v1",
    aiModel: str(env.AI_MODEL) ?? "deepseek-v4.1-flash",
    aiReasoningMode: oneOf(env.AI_REASONING_MODE, ["off", "low", "high", "max"] as const, "off"),
    aiMaxOutputTokens: Math.min(
      positiveInt(env.AI_MAX_OUTPUT_TOKENS, DEFAULT_AI_MAX_OUTPUT_TOKENS),
      AI_MAX_OUTPUT_TOKENS_CAP,
    ),
    aiTimeoutMs: positiveInt(env.AI_TIMEOUT_MS, DEFAULT_AI_TIMEOUT_MS),
    aiSessionId: str(env.AI_SESSION_ID) ?? "valentinvera-reviewer",

    queuePollMs: int(env.QUEUE_POLL_MS, 1_000),
    jobMaxAttempts: int(env.JOB_MAX_ATTEMPTS, 3),
    workerConcurrency: Math.max(1, int(env.WORKER_CONCURRENCY, 1)),
    workerEnabled: bool(env.WORKER_ENABLED, true),

    reviewMaxDiffChars: int(env.REVIEW_MAX_DIFF_CHARS, 240_000),
    reviewMaxFindings: int(env.REVIEW_MAX_FINDINGS, 12),
    reviewChunkChars: int(env.REVIEW_CHUNK_CHARS, 16_000),
    reviewAutoMaxPerPr24h: int(env.REVIEW_AUTO_MAX_PER_PR_24H, 10),
    reviewManualCooldownSeconds: int(env.REVIEW_MANUAL_COOLDOWN_SECONDS, 600),
    reviewManualMaxPerPr24h: int(env.REVIEW_MANUAL_MAX_PER_PR_24H, 5),
    reviewGlobalMax24h: int(env.REVIEW_GLOBAL_MAX_24H, 50),
    reviewSkipAuthors: list(env.REVIEW_SKIP_AUTHORS, DEFAULT_REVIEW_SKIP_AUTHORS),
  }
}

export const config = loadConfig()
