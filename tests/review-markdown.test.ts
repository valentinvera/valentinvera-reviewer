import { afterEach, describe, expect, test } from "bun:test"
import { config } from "../src/config"
import { buildRateLimitNotice, type RateLimitReason } from "../src/review/markdown"

const reasons: RateLimitReason[] = [
  "auto_per_pr_24h",
  "manual_per_pr_24h",
  "manual_cooldown",
  "global_24h",
]

const defaults = {
  reviewManualCooldownSeconds: config.reviewManualCooldownSeconds,
}

afterEach(() => {
  config.reviewManualCooldownSeconds = defaults.reviewManualCooldownSeconds
})

describe("buildRateLimitNotice", () => {
  test("maps each reason to a distinct message", () => {
    config.reviewManualCooldownSeconds = 600

    const messages = reasons.map((reason) => buildRateLimitNotice(reason))

    expect(new Set(messages).size).toBe(reasons.length)
    expect(buildRateLimitNotice("auto_per_pr_24h")).toContain(
      "Automatic review limit reached for this pull request",
    )
    expect(buildRateLimitNotice("manual_per_pr_24h")).toContain(
      "Manual review limit reached for this pull request",
    )
    expect(buildRateLimitNotice("manual_cooldown")).toContain(
      "wait about 10 minute(s) before requesting /review again",
    )
    expect(buildRateLimitNotice("global_24h")).toContain(
      "global daily review limit (across all repositories)",
    )
  })

  test("does not mention this PR in the global limit notice", () => {
    expect(buildRateLimitNotice("global_24h")).not.toContain("this pull request")
  })
})
