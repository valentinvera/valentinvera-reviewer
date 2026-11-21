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
  const sections = [`**${SEVERITY_LABEL[finding.severity]} · ${finding.title}**`, "", finding.body]

  const suggestion = finding.suggestion?.trim()
  if (suggestion) {
    sections.push("", "```suggestion", suggestion, "```")
  }

  return sections.join("\n")
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
  incremental?: boolean
}): string {
  const sections: string[] = [
    "### 💡 Code Review",
    input.incremental
      ? "Here are automated review suggestions for the new commits on this pull request."
      : "Here are some automated review suggestions for this pull request.",
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

export function buildFailureComment(errorMessage?: string): string {
  const detail = errorMessage?.trim()
    ? `\n\n<details><summary>Error detail</summary>\n\n\`\`\`\n${errorMessage.trim().slice(0, 1_000)}\n\`\`\`\n\n</details>`
    : ""

  return [
    "## Code Review failed",
    "",
    "The automated review did not complete after several attempts.",
    "Comment `/review` to retry.",
    detail,
  ].join("\n")
}

export function buildMaxRoundsNotice(maxRounds: number): string {
  return [
    "## Automatic reviews paused",
    "",
    `This pull request reached the limit of ${maxRounds} automatic review rounds.`,
    "Comment `/review` to run another review manually.",
  ].join("\n")
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
  incremental?: boolean
  resolvedCount?: number
}): string {
  const clean = input.findingsCount === 0
  const review = input.reviewUrl ? `[📝 Code Review](${input.reviewUrl})` : "📝 Code Review"
  const status = clean
    ? input.incremental
      ? "✅ Completed, no new issues"
      : "✅ Completed, no issues found"
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
  ]

  if (clean) {
    lines.push(
      input.incremental
        ? "No new issues found in the latest commits."
        : "No issues found. Nice work! 🎉",
    )
  } else {
    lines.push("See the inline comments in the review for the suggested changes.")
  }

  if (input.resolvedCount && input.resolvedCount > 0) {
    lines.push("", `Resolved ${pluralize(input.resolvedCount, "prior review thread")}.`)
  }

  lines.push(
    "",
    ...(input.truncated ? [TRUNCATED_NOTICE, ""] : []),
    `<sub>${input.model} · this comment is updated on every review · comment \`/review\` to run it again</sub>`,
  )

  return lines.join("\n")
}
