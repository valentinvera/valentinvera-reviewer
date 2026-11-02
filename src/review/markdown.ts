import { config } from "../config"
import type { Finding } from "./schema"

const TRUNCATED_NOTICE =
  "> ⚠️ The diff exceeded the configured size limit, so only part of it was reviewed."

const SEVERITY_LABEL: Record<Finding["severity"], string> = {
  critical: "🔴 critical",
  high: "🟠 high",
  medium: "🟡 medium",
  low: "🔵 low",
}

export function buildInlineComment(finding: Finding): string {
  return `**${SEVERITY_LABEL[finding.severity]} · ${finding.title}**\n\n${finding.body}`
}

export function shortSha(sha: string): string {
  return sha.slice(0, 10)
}

function pluralize(count: number, singular: string): string {
  return `${count} ${singular}${count === 1 ? "" : "s"}`
}

/**
 * Short top-level review body. The details live in the inline comments, so
 * there is no prose summary here.
 */
export function buildReviewBody(input: {
  findingsCount: number
  headSha: string
  model: string
  unanchored: Finding[]
  truncated: boolean
}): string {
  const sections: string[] = [
    "### 💡 Code Review",
    "Here are some automated review suggestions for this pull request.",
    `**Reviewed commit:** \`${shortSha(input.headSha)}\``,
  ]

  if (input.unanchored.length > 0) {
    sections.push(
      [
        "**General findings** (not tied to a diff line):",
        "",
        ...input.unanchored.map(
          (finding) =>
            `- **${SEVERITY_LABEL[finding.severity]} · ${finding.title}** — ${finding.body}`,
        ),
      ].join("\n"),
    )
  }

  if (input.truncated) {
    sections.push(
      "> ⚠️ The diff exceeded the configured size limit, so only part of it was reviewed.",
    )
  }

  sections.push(`<sub>${input.model} · ${pluralize(input.findingsCount, "finding")}</sub>`)

  return sections.join("\n\n")
}

export type RateLimitReason =
  | "auto_per_pr_24h"
  | "manual_per_pr_24h"
  | "manual_cooldown"
  | "global_24h"

export function buildRateLimitNotice(reason: RateLimitReason): string {
  const cooldownMinutes = Math.max(1, Math.ceil(config.reviewManualCooldownSeconds / 60))

  switch (reason) {
    case "auto_per_pr_24h":
      return "⏳ Automatic review limit reached for this pull request. Reviews will resume once the 24-hour window allows."
    case "manual_per_pr_24h":
      return "⏳ Manual review limit reached for this pull request. Please try again later."
    case "manual_cooldown":
      return `⏳ A manual review ran recently. Please wait about ${cooldownMinutes} minute(s) before requesting /review again.`
    case "global_24h":
      return "⏳ The bot's global daily review limit (across all repositories) was reached. Reviews will resume once the 24-hour window allows."
  }
}

/**
 * Status comment that is created once per PR and updated on every review.
 * When the review found nothing, this comment is the only output.
 */
export function buildSummaryComment(input: {
  findingsCount: number
  headSha: string
  model: string
  /** Link to the published review; null when no review was posted. */
  reviewUrl: string | null
  trigger: string
  truncated: boolean
}): string {
  const clean = input.findingsCount === 0
  const review = input.reviewUrl ? `[📝 Code Review](${input.reviewUrl})` : "📝 Code Review"
  const status = clean
    ? "✅ Completed, no issues found"
    : `💡 Completed, ${pluralize(input.findingsCount, "finding")}`

  const lines = [
    "## Code Review Summary",
    "",
    "This comment shows the latest review activity on this pull request.",
    "",
    "| Review | Status | Commit | Review trigger |",
    "| --- | --- | --- | --- |",
    `| ${review} | ${status} | \`${shortSha(input.headSha)}\` | ${input.trigger} |`,
    "",
    clean
      ? "No issues found. Nice work! 🎉"
      : "See the inline comments in the review for the suggested changes.",
    "",
    ...(input.truncated ? [TRUNCATED_NOTICE, ""] : []),
    `<sub>${input.model} · this comment is updated on every review · comment \`/review\` to run it again</sub>`,
  ]

  return lines.join("\n")
}
