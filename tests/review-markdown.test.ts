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
  reviewLanguage: config.reviewLanguage,
  reviewManualCooldownSeconds: config.reviewManualCooldownSeconds,
}

afterEach(() => {
  config.reviewLanguage = defaults.reviewLanguage
  config.reviewManualCooldownSeconds = defaults.reviewManualCooldownSeconds
})

describe("buildRateLimitNotice", () => {
  test("maps each reason to a distinct English message", () => {
    config.reviewLanguage = "en"
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

  test("maps each reason to a distinct Spanish message", () => {
    config.reviewLanguage = "es"
    config.reviewManualCooldownSeconds = 600

    const messages = reasons.map((reason) => buildRateLimitNotice(reason))

    expect(new Set(messages).size).toBe(reasons.length)
    expect(buildRateLimitNotice("auto_per_pr_24h")).toContain(
      "límite de reviews automáticos de este PR",
    )
    expect(buildRateLimitNotice("manual_per_pr_24h")).toContain(
      "límite de reviews manuales de este PR",
    )
    expect(buildRateLimitNotice("manual_cooldown")).toContain(
      "Esperá unos 10 minuto(s) antes de volver a pedir /review",
    )
    expect(buildRateLimitNotice("global_24h")).toContain(
      "límite global diario de reviews del bot (en todos los repositorios)",
    )
  })

  test("does not mention this PR in the global limit notice", () => {
    config.reviewLanguage = "en"
    expect(buildRateLimitNotice("global_24h")).not.toContain("this pull request")

    config.reviewLanguage = "es"
    expect(buildRateLimitNotice("global_24h")).not.toContain("este PR")
  })
})
