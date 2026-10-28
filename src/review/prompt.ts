import type { ReviewLanguage } from "../config"

export interface ReviewPullRequest {
  number: number
  title: string
  body: string | null
  author: string
  baseRef: string
  headRef: string
  baseSha: string
  headSha: string
  changedFiles: number
  additions: number
  deletions: number
}

export interface ReviewPromptInput {
  repo: string
  pr: ReviewPullRequest
  diff: string
  truncated: boolean
  maxFindings: number
  language: ReviewLanguage
  /** Set when the diff is reviewed in several calls. */
  scope?: { index: number; total: number } | null
}

const LANGUAGE_NAME: Record<ReviewLanguage, string> = {
  es: "Spanish (rioplatense, neutral and professional)",
  en: "English",
}

export function buildReviewPrompt(input: ReviewPromptInput): { system: string; prompt: string } {
  const { pr } = input

  const system = [
    "You are valentinvera-reviewer, a senior software engineer performing an automated pull request review.",
    "Your job is to find real problems introduced by this change, not to praise the author or rewrite the code.",
    "",
    "Focus on, in this order:",
    "1. Correctness bugs, edge cases, null/undefined handling, off-by-one errors.",
    "2. Security issues: injection, authn/authz gaps, secrets, unsafe input handling, SSRF.",
    "3. Data loss, migrations, race conditions, error handling that swallows failures.",
    "4. Performance regressions with a plausible impact at realistic scale.",
    "5. Missing tests only when the changed behaviour is risky and untested.",
    "",
    "Rules:",
    "- Only report issues that are visible in the provided diff. Never invent files or lines.",
    "- Every finding MUST anchor to a line that exists in the diff.",
    "- Use side RIGHT and the new-file line number for added or context lines.",
    "- Use side LEFT and the old-file line number only for removed lines.",
    "- Do not comment on formatting, naming or style unless it causes a real bug.",
    "- Do not repeat the same issue in multiple findings.",
    `- Return at most ${input.maxFindings} findings, ordered by severity.`,
    "- If there is nothing significant, return an empty findings array and say so in the summary.",
    "- Be concrete: explain the failure mode and the fix. No generic advice, no filler.",
    "",
    `Write the summary and every finding body in ${LANGUAGE_NAME[input.language]}.`,
    "Keep code identifiers, file paths and error messages as-is.",
  ].join("\n")

  const prompt = [
    `Repository: ${input.repo}`,
    `Pull request #${pr.number}: ${pr.title}`,
    `Author: ${pr.author}`,
    `Branch: ${pr.headRef} (${pr.headSha.slice(0, 10)}) -> ${pr.baseRef} (${pr.baseSha.slice(0, 10)})`,
    `Size: ${pr.changedFiles} files, +${pr.additions} / -${pr.deletions}`,
    "",
    "Pull request description:",
    pr.body?.trim() ? pr.body.trim() : "(no description provided)",
    "",
    input.truncated
      ? "Unified diff (TRUNCATED because of size; review only what is shown):"
      : "Unified diff:",
    input.scope
      ? `(Part ${input.scope.index} of ${input.scope.total}: this call only contains a subset of the changed files.)`
      : "",
    "<diff>",
    input.diff,
    "</diff>",
    "",
    "Review this diff now.",
  ].join("\n")

  return { system, prompt }
}
