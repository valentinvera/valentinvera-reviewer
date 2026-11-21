import { describe, expect, test } from "bun:test"
import { buildReviewPrompt, extractBotThreads } from "../src/review/prompt"
import type { ReviewThread } from "../src/review/publisher"

const pr = {
  number: 51,
  title: "feat: change",
  body: "desc",
  author: "valen",
  baseRef: "main",
  headRef: "feat",
  baseSha: "b".repeat(40),
  headSha: "a".repeat(40),
  changedFiles: 1,
  additions: 1,
  deletions: 0,
}

describe("buildReviewPrompt", () => {
  test("includes prior threads, dismissals, and repo rules", () => {
    const { system, prompt } = buildReviewPrompt({
      repo: "o/r",
      pr,
      diff: "diff",
      truncated: false,
      maxFindings: 5,
      mode: "incremental",
      comparedFromSha: "c".repeat(40),
      priorThreads: [
        {
          id: "PRRT_1",
          isResolved: false,
          path: "src/a.ts",
          line: 2,
          title: "Bug",
          body: "old finding",
          replies: [{ author: "valen", body: "looking" }],
        },
      ],
      learnedDismissals: [
        {
          id: 1,
          repo: "o/r",
          path: "src/b.ts",
          title: "Style nit",
          body: "ignored",
          reason: "reply",
          sourceCommentId: 9,
          createdAt: 1,
        },
      ],
      repoRules: "Always check migrations.",
      agentsMd: "Use conventional commits.",
    })

    expect(system).toContain("incremental re-review")
    expect(prompt).toContain("Prior bot review threads")
    expect(prompt).toContain("PRRT_1")
    expect(prompt).toContain("Style nit")
    expect(prompt).toContain("Always check migrations.")
    expect(prompt).toContain("Use conventional commits.")
    expect(prompt).toContain("Incremental base")
  })
})

describe("extractBotThreads", () => {
  test("keeps bot-authored threads and replies", () => {
    const threads: ReviewThread[] = [
      {
        id: "PRRT_1",
        isResolved: false,
        path: "src/a.ts",
        line: 1,
        comments: [
          {
            id: 1,
            body: "**🟠 high · Null check**\n\nMissing guard.",
            path: "src/a.ts",
            line: 1,
            author: "valentinvera-reviewer[bot]",
            createdAt: "2026-01-01T00:00:00Z",
            isBot: true,
          },
          {
            id: 2,
            body: "will fix",
            path: "src/a.ts",
            line: 1,
            author: "valen",
            createdAt: "2026-01-01T01:00:00Z",
            isBot: false,
          },
        ],
      },
      {
        id: "PRRT_2",
        isResolved: true,
        path: "src/b.ts",
        line: 2,
        comments: [
          {
            id: 3,
            body: "human note",
            path: "src/b.ts",
            line: 2,
            author: "valen",
            createdAt: "2026-01-01T00:00:00Z",
            isBot: false,
          },
        ],
      },
    ]

    const extracted = extractBotThreads(threads, ["valentinvera-reviewer"])
    expect(extracted).toHaveLength(1)
    expect(extracted[0]?.title).toBe("Null check")
    expect(extracted[0]?.replies).toHaveLength(1)
  })
})
