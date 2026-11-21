import type { LearnedDismissal } from "./store"
import type { ReviewThread } from "./publisher"

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

export type ReviewMode = "full" | "incremental"

export interface PriorBotThread {
  id: string
  isResolved: boolean
  path: string | null
  line: number | null
  title: string
  body: string
  replies: Array<{ author: string; body: string }>
}

export interface ReviewPromptInput {
  repo: string
  pr: ReviewPullRequest
  diff: string
  truncated: boolean
  maxFindings: number
  /** Set when the diff is reviewed in several calls. */
  scope?: { index: number; total: number } | null
  mode?: ReviewMode
  comparedFromSha?: string | null
  priorThreads?: PriorBotThread[]
  learnedDismissals?: LearnedDismissal[]
  repoRules?: string | null
  agentsMd?: string | null
}

function formatPriorThreads(threads: PriorBotThread[]): string {
  if (threads.length === 0) return "(none)"

  return threads
    .map((thread) => {
      const location = thread.path
        ? `${thread.path}${thread.line ? `:${thread.line}` : ""}`
        : "(no path)"
      const replies =
        thread.replies.length === 0
          ? "  (no replies)"
          : thread.replies
              .map((reply) => `  - ${reply.author}: ${reply.body.slice(0, 400)}`)
              .join("\n")

      return [
        `- threadId=${thread.id} resolved=${thread.isResolved} ${location}`,
        `  title: ${thread.title}`,
        `  body: ${thread.body.slice(0, 600)}`,
        `  replies:`,
        replies,
      ].join("\n")
    })
    .join("\n")
}

function formatDismissals(dismissals: LearnedDismissal[]): string {
  if (dismissals.length === 0) return "(none)"

  return dismissals
    .map((item) => {
      const location = item.path ? ` path=${item.path}` : ""
      return `- [${item.reason}]${location} ${item.title}${item.body ? ` — ${item.body.slice(0, 200)}` : ""}`
    })
    .join("\n")
}

export function extractBotThreads(threads: ReviewThread[], botLogins: string[]): PriorBotThread[] {
  const bots = new Set(botLogins.map((login) => login.toLowerCase()))

  return threads
    .map((thread) => {
      const root = thread.comments[0]
      if (!root) return null

      const authoredByBot =
        root.isBot ||
        bots.has(root.author.toLowerCase()) ||
        /code review|severity ·/i.test(root.body)
      if (!authoredByBot) return null

      const titleMatch = /^\*\*[^*]+·\s*(.+?)\*\*/.exec(root.body)
      const title = titleMatch?.[1]?.trim() || root.body.split("\n")[0]?.slice(0, 80) || "Finding"

      return {
        id: thread.id,
        isResolved: thread.isResolved,
        path: thread.path ?? root.path,
        line: thread.line ?? root.line,
        title,
        body: root.body,
        replies: thread.comments.slice(1).map((comment) => ({
          author: comment.author,
          body: comment.body,
        })),
      } satisfies PriorBotThread
    })
    .filter((thread): thread is PriorBotThread => thread !== null)
}

export function buildReviewPrompt(input: ReviewPromptInput): { system: string; prompt: string } {
  const { pr } = input
  const mode = input.mode ?? "full"
  const incremental = mode === "incremental"

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
    "- Do not re-report issues already listed under prior bot review threads unless the bug is still present AND you have new evidence. Prefer listing their thread id in fixedThreadIds when the new code fixes them.",
    "- Do not re-report issues listed under learned dismissals.",
    `- Return at most ${input.maxFindings} findings, ordered by severity.`,
    "- If there is nothing significant, return an empty findings array and say so in the summary.",
    "- Be concrete: explain the failure mode and the fix. No generic advice, no filler.",
    "- When a fix is a small, exact replacement of the commented lines, set `suggestion` to the exact new text (no diff markers). Set `startLine` when the replacement spans multiple lines.",
    "",
    incremental
      ? [
          "This is an incremental re-review of new commits only:",
          "- Verify whether prior unresolved bot findings were fixed; put fixed thread ids in fixedThreadIds.",
          "- Flag only new issues introduced by the new commits.",
          "- For nits unrelated to the changed lines, only report high or critical severity.",
          "- If nothing new remains, return an empty findings array.",
        ].join("\n")
      : "This is a full review of the pull request diff.",
    "",
    "Write the summary and every finding title and body in English, even when the pull request, its description or code comments are in another language.",
    "Keep code identifiers, file paths and error messages as-is.",
  ].join("\n")

  const rulesSection = input.repoRules?.trim()
    ? ["Repository review rules (.reviewer/rules.md):", input.repoRules.trim(), ""]
    : []
  const agentsSection = input.agentsMd?.trim()
    ? ["Repository agent guidance (AGENTS.md):", input.agentsMd.trim(), ""]
    : []

  const prompt = [
    `Repository: ${input.repo}`,
    `Pull request #${pr.number}: ${pr.title}`,
    `Author: ${pr.author}`,
    `Branch: ${pr.headRef} (${pr.headSha.slice(0, 10)}) -> ${pr.baseRef} (${pr.baseSha.slice(0, 10)})`,
    `Size: ${pr.changedFiles} files, +${pr.additions} / -${pr.deletions}`,
    `Review mode: ${mode}`,
    input.comparedFromSha
      ? `Incremental base (last reviewed SHA): ${input.comparedFromSha.slice(0, 10)}`
      : "",
    "",
    "Pull request description:",
    pr.body?.trim() ? pr.body.trim() : "(no description provided)",
    "",
    ...rulesSection,
    ...agentsSection,
    "Prior bot review threads (do not re-post these unless still broken):",
    formatPriorThreads(input.priorThreads ?? []),
    "",
    "Learned dismissals for this repository (treat as false positives unless clearly wrong now):",
    formatDismissals(input.learnedDismissals ?? []),
    "",
    input.truncated
      ? "Unified diff (TRUNCATED because of size; review only what is shown):"
      : incremental
        ? "Unified diff of new commits since the last reviewed SHA:"
        : "Unified diff:",
    input.scope
      ? `(Part ${input.scope.index} of ${input.scope.total}: this call only contains a subset of the changed files.)`
      : "",
    "<diff>",
    input.diff,
    "</diff>",
    "",
    "Review this diff now.",
  ]
    .filter((line) => line !== "")
    .join("\n")

  return { system, prompt }
}
