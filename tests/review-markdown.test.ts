import { afterEach, describe, expect, test } from "bun:test"
import { config } from "../src/config"
import {
  buildInlineComment,
  buildRateLimitNotice,
  buildReviewBody,
  type RateLimitReason,
} from "../src/review/markdown"
import type { Finding } from "../src/review/schema"

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

const finding: Finding = {
  path: "src/a.ts",
  line: 3,
  side: "RIGHT",
  severity: "high",
  title: "Null dereference",
  body: "`user` can be undefined here.",
}

describe("buildInlineComment", () => {
  test("renders the severity label and title in bold, then the body", () => {
    expect(buildInlineComment(finding)).toBe(
      "**🟠 high · Null dereference**\n\n`user` can be undefined here.",
    )
  })
})

describe("buildReviewBody", () => {
  const base = {
    findingsCount: 2,
    headSha: "4a627cffa2b3c4d5e6f7",
    model: "mock-model",
    unanchored: [] as Finding[],
    truncated: false,
  }

  test("renders a short Codex-style header without a prose summary", () => {
    expect(buildReviewBody(base)).toBe(
      [
        "### 💡 Code Review",
        "Here are some automated review suggestions for this pull request.",
        "**Reviewed commit:** `4a627cffa2`",
        "<sub>mock-model · 2 findings</sub>",
      ].join("\n\n"),
    )
  })

  test("uses the singular for one finding", () => {
    expect(buildReviewBody({ ...base, findingsCount: 1 })).toContain("· 1 finding</sub>")
  })

  test("lists findings that cannot be anchored inline", () => {
    const body = buildReviewBody({ ...base, unanchored: [finding] })

    expect(body).toContain("**General findings** (not tied to a diff line):")
    expect(body).toContain("- **🟠 high · Null dereference** — `user` can be undefined here.")
  })

  test("warns when the diff was truncated", () => {
    expect(buildReviewBody({ ...base, truncated: true })).toContain("only part of it was reviewed")
  })
})
