import { describe, expect, test } from "bun:test"
import { loadConfig } from "../src/config"

describe("loadConfig", () => {
  test("uses defaults for an empty environment", () => {
    const config = loadConfig({})

    expect(config.port).toBe(3000)
    expect(config.hostname).toBe("0.0.0.0")
    expect(config.databasePath).toBe("./data/reviewer.db")
    expect(config.aiModel).toBe("deepseek-v4.1-flash")
    expect(config.aiReasoningMode).toBe("off")
    expect(config.workerConcurrency).toBe(1)
    expect(config.jobMaxAttempts).toBe(3)
    expect(config.queuePollMs).toBe(1000)
    expect(config.workerEnabled).toBe(true)
    expect(config.reviewLanguage).toBe("es")
    expect(config.reviewMaxDiffChars).toBe(240_000)
    expect(config.reviewMaxFindings).toBe(12)
    expect(config.reviewChunkChars).toBe(16_000)
    expect(config.reviewAutoMaxPerPr24h).toBe(10)
    expect(config.reviewManualCooldownSeconds).toBe(600)
    expect(config.reviewManualMaxPerPr24h).toBe(5)
    expect(config.reviewGlobalMax24h).toBe(50)
    expect(config.maxRequestBodyBytes).toBe(10 * 1024 * 1024)
  })

  test("parses overrides", () => {
    const config = loadConfig({
      PORT: "4000",
      HOST: "127.0.0.1",
      WORKER_CONCURRENCY: "3",
      WORKER_ENABLED: "false",
      REVIEW_LANGUAGE: "en",
      REVIEW_MAX_DIFF_CHARS: "1000",
      REVIEW_MAX_FINDINGS: "5",
      REVIEW_CHUNK_CHARS: "8000",
      REVIEW_AUTO_MAX_PER_PR_24H: "7",
      REVIEW_MANUAL_COOLDOWN_SECONDS: "120",
      REVIEW_MANUAL_MAX_PER_PR_24H: "3",
      REVIEW_GLOBAL_MAX_24H: "25",
      JOB_MAX_ATTEMPTS: "5",
      AI_REASONING_MODE: "low",
      LOG_LEVEL: "debug",
      MAX_REQUEST_BODY_BYTES: "2048",
    })

    expect(config.port).toBe(4000)
    expect(config.hostname).toBe("127.0.0.1")
    expect(config.workerConcurrency).toBe(3)
    expect(config.workerEnabled).toBe(false)
    expect(config.reviewLanguage).toBe("en")
    expect(config.reviewMaxDiffChars).toBe(1_000)
    expect(config.reviewMaxFindings).toBe(5)
    expect(config.reviewChunkChars).toBe(8_000)
    expect(config.reviewAutoMaxPerPr24h).toBe(7)
    expect(config.reviewManualCooldownSeconds).toBe(120)
    expect(config.reviewManualMaxPerPr24h).toBe(3)
    expect(config.reviewGlobalMax24h).toBe(25)
    expect(config.jobMaxAttempts).toBe(5)
    expect(config.aiReasoningMode).toBe("low")
    expect(config.logLevel).toBe("debug")
    expect(config.maxRequestBodyBytes).toBe(2_048)
  })

  test("falls back on invalid values", () => {
    const config = loadConfig({
      PORT: "not-a-number",
      WORKER_CONCURRENCY: "0",
      AI_REASONING_MODE: "invalid",
      LOG_LEVEL: "invalid",
      MAX_REQUEST_BODY_BYTES: "not-a-number",
    })

    expect(config.port).toBe(3000)
    expect(config.workerConcurrency).toBe(1)
    expect(config.aiReasoningMode).toBe("off")
    expect(config.logLevel).toBe("info")
    expect(config.maxRequestBodyBytes).toBe(10 * 1024 * 1024)
  })
})
