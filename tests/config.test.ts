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
      JOB_MAX_ATTEMPTS: "5",
      AI_REASONING_MODE: "low",
      LOG_LEVEL: "debug",
    })

    expect(config.port).toBe(4000)
    expect(config.hostname).toBe("127.0.0.1")
    expect(config.workerConcurrency).toBe(3)
    expect(config.workerEnabled).toBe(false)
    expect(config.reviewLanguage).toBe("en")
    expect(config.reviewMaxDiffChars).toBe(1_000)
    expect(config.reviewMaxFindings).toBe(5)
    expect(config.reviewChunkChars).toBe(8_000)
    expect(config.jobMaxAttempts).toBe(5)
    expect(config.aiReasoningMode).toBe("low")
    expect(config.logLevel).toBe("debug")
  })

  test("falls back on invalid values", () => {
    const config = loadConfig({
      PORT: "not-a-number",
      WORKER_CONCURRENCY: "0",
      AI_REASONING_MODE: "invalid",
      LOG_LEVEL: "invalid",
    })

    expect(config.port).toBe(3000)
    expect(config.workerConcurrency).toBe(1)
    expect(config.aiReasoningMode).toBe("off")
    expect(config.logLevel).toBe("info")
  })
})
