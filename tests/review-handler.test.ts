import { afterEach, beforeEach, describe, expect, test } from "bun:test"
import { config } from "../src/config"
import { db } from "../src/db"
import type { GeneratedReview } from "../src/review/engine"
import { processReviewJob, type ReviewJobPayload } from "../src/review/handler"
import type {
  CheckRunInput,
  CreateReviewInput,
  PullRequestForReview,
  ReviewGitHubClient,
} from "../src/review/publisher"
import {
  countReviewRuns,
  getAutoReviewRounds,
  getLastReviewedSha,
  getSummaryCommentId,
  hasReviewed,
  incrementAutoReviewRounds,
  markReviewed,
  recordReviewRun,
  setSummaryCommentId,
  type ReviewRunKind,
} from "../src/review/store"

const pr: PullRequestForReview = {
  number: 51,
  title: "feat: change things",
  body: null,
  author: "valentinvera",
  baseRef: "main",
  headRef: "feat/change",
  baseSha: "b".repeat(40),
  headSha: "abc123def456",
  changedFiles: 1,
  additions: 1,
  deletions: 1,
  state: "open",
  draft: false,
  htmlUrl: "https://github.com/valentinvera/plata/pull/51",
}

const diff = `diff --git a/src/a.ts b/src/a.ts
--- a/src/a.ts
+++ b/src/a.ts
@@ -1,2 +1,2 @@
 const a = 1
-const b = 2
+const b = 3
`

const generated: GeneratedReview = {
  result: {
    summary: "Summary text",
    verdict: "needs_changes",
    findings: [
      {
        path: "src/a.ts",
        line: 1,
        side: "RIGHT",
        severity: "high",
        title: "One",
        body: "Body",
      },
      {
        path: "src/a.ts",
        line: 99,
        side: "RIGHT",
        severity: "low",
        title: "Two",
        body: "Body2",
      },
    ],
  },
  clipped: { diff, truncated: false, originalChars: diff.length },
  model: "mock-model",
  durationMs: 1,
  usage: undefined,
}

const clean: GeneratedReview = {
  ...generated,
  result: { summary: "Looks good.", verdict: "looks_good", findings: [] },
}

const payload: ReviewJobPayload = {
  installationId: 99,
  repo: "valentinvera/plata",
  prNumber: 51,
  headSha: pr.headSha,
  action: "opened",
}

interface Calls {
  reviews: CreateReviewInput[]
  comments: string[]
  updates: Array<{ id: number; body: string }>
  checks: CheckRunInput[]
  checkUpdates: Array<{ id: number; status: string; conclusion?: string }>
  compares: Array<{ base: string; head: string }>
  resolvedThreads: string[]
}

function fakeClient(overrides: Partial<ReviewGitHubClient> = {}) {
  const calls: Calls = {
    reviews: [],
    comments: [],
    updates: [],
    checks: [],
    checkUpdates: [],
    compares: [],
    resolvedThreads: [],
  }

  let checkId = 100

  const client: ReviewGitHubClient = {
    getPullRequest: async () => pr,
    getPullRequestDiff: async () => diff,
    compareCommits: async (_repo, base, head) => {
      calls.compares.push({ base, head })
      return { status: "ahead", aheadBy: 1, behindBy: 0, diff }
    },
    getFileContent: async () => null,
    listReviewThreads: async () => [],
    resolveReviewThread: async (threadId) => {
      calls.resolvedThreads.push(threadId)
    },
    getPullRequestReviewComment: async (_repo, commentId) => ({
      id: commentId,
      body: "**🟠 high · Bug**\n\nBody",
      path: "src/a.ts",
      line: 1,
      originalLine: 1,
      user: "valentinvera-reviewer[bot]",
      inReplyToId: null,
      htmlUrl: "https://example.com",
    }),
    listCommentReactions: async () => [],
    createCheckRun: async (_repo, input) => {
      calls.checks.push(input)
      checkId += 1
      return { id: checkId }
    },
    updateCheckRun: async (_repo, id, input) => {
      calls.checkUpdates.push({
        id,
        status: input.status,
        conclusion: input.conclusion,
      })
      return { id }
    },
    createReview: async (_repo, _pr, input) => {
      calls.reviews.push(input)
      return { id: 1, html_url: "https://github.com/review/1" }
    },
    createIssueComment: async (_repo, _pr, body) => {
      calls.comments.push(body)
      return { id: 10 }
    },
    updateIssueComment: async (_repo, id, body) => {
      calls.updates.push({ id, body })
      return { id }
    },
    ...overrides,
  }

  return { client, calls }
}

const rateLimitDefaults = {
  reviewAutoMaxPerPr24h: config.reviewAutoMaxPerPr24h,
  reviewManualCooldownSeconds: config.reviewManualCooldownSeconds,
  reviewManualMaxPerPr24h: config.reviewManualMaxPerPr24h,
  reviewGlobalMax24h: config.reviewGlobalMax24h,
  reviewAutoMaxRounds: config.reviewAutoMaxRounds,
}

function seedRuns(input: {
  repo?: string
  prNumber?: number
  kind?: ReviewRunKind
  count: number
  createdAt?: number
}) {
  for (let index = 0; index < input.count; index += 1) {
    recordReviewRun({
      repo: input.repo ?? payload.repo,
      prNumber: input.prNumber ?? payload.prNumber,
      kind: input.kind ?? "auto",
      createdAt: input.createdAt ?? Date.now(),
    })
  }
}

beforeEach(() => {
  db.exec(`
    DELETE FROM reviewed_commits;
    DELETE FROM summary_comments;
    DELETE FROM review_runs;
    DELETE FROM review_rate_limit_notices;
    DELETE FROM review_auto_rounds;
    DELETE FROM learned_dismissals;
    DELETE FROM active_reviews;
    DELETE FROM failure_comments;
  `)
})

afterEach(() => {
  config.reviewAutoMaxPerPr24h = rateLimitDefaults.reviewAutoMaxPerPr24h
  config.reviewManualCooldownSeconds = rateLimitDefaults.reviewManualCooldownSeconds
  config.reviewManualMaxPerPr24h = rateLimitDefaults.reviewManualMaxPerPr24h
  config.reviewGlobalMax24h = rateLimitDefaults.reviewGlobalMax24h
  config.reviewAutoMaxRounds = rateLimitDefaults.reviewAutoMaxRounds
})

describe("processReviewJob", () => {
  test("publishes anchored review comments and a summary comment", async () => {
    const { client, calls } = fakeClient()

    await processReviewJob(payload, {
      getClient: async () => client,
      generateReview: async () => generated,
    })

    expect(calls.reviews).toHaveLength(1)
    expect(calls.reviews[0]?.comments).toHaveLength(1)
    expect(calls.reviews[0]?.comments[0]?.path).toBe("src/a.ts")
    expect(calls.reviews[0]?.body).toContain("General findings")
    expect(calls.reviews[0]?.body).toContain("Two")
    expect(calls.reviews[0]?.body).toContain("### 💡 Code Review")
    expect(calls.reviews[0]?.body).toContain("**Reviewed commit:** `abc123def4`")
    expect(calls.reviews[0]?.body).not.toContain("Summary text")
    expect(calls.comments).toHaveLength(1)
    expect(calls.comments[0]).toContain("## Code Review Summary")
    expect(calls.comments[0]).toContain("💡 Completed, 2 findings")
    expect(calls.comments[0]).toContain("[📝 Code Review](https://github.com/review/1)")
    expect(calls.comments[0]).toContain("| PR opened |")
    expect(hasReviewed(payload.repo, payload.prNumber, payload.headSha!)).toBe(true)
    expect(calls.checks).toHaveLength(1)
    expect(calls.checks[0]?.status).toBe("in_progress")
    expect(calls.checkUpdates.at(-1)?.conclusion).toBe("neutral")
  })

  test("posts only a summary comment when the review finds no issues", async () => {
    const { client, calls } = fakeClient()

    await processReviewJob(payload, {
      getClient: async () => client,
      generateReview: async () => clean,
    })

    expect(calls.reviews).toHaveLength(0)
    expect(calls.comments).toHaveLength(1)
    expect(calls.comments[0]).toContain("## Code Review Summary")
    expect(calls.comments[0]).toContain(
      "| 📝 Code Review | ✅ Completed, no issues found | `abc123def4` | PR opened |",
    )
    expect(calls.comments[0]).toContain("No issues found. Nice work! 🎉")
    expect(getSummaryCommentId(payload.repo, payload.prNumber)).toBe(10)
    expect(hasReviewed(payload.repo, payload.prNumber, payload.headSha!)).toBe(true)
    expect(calls.checkUpdates.at(-1)?.conclusion).toBe("success")
  })

  test("updates the existing summary comment on a clean manual review", async () => {
    setSummaryCommentId(payload.repo, payload.prNumber, 55)
    const { client, calls } = fakeClient()

    await processReviewJob(
      { ...payload, headSha: "", action: "manual", force: true },
      {
        getClient: async () => client,
        generateReview: async () => clean,
      },
    )

    expect(calls.reviews).toHaveLength(0)
    expect(calls.comments).toHaveLength(0)
    expect(calls.updates).toHaveLength(1)
    expect(calls.updates[0]?.id).toBe(55)
    expect(calls.updates[0]?.body).toContain("| /review command |")
  })

  test("maps the webhook action to the review trigger label", async () => {
    const cases: Array<[string, string]> = [
      ["synchronize", "New commits pushed"],
      ["reopened", "PR reopened"],
      ["ready_for_review", "Ready for review"],
    ]

    for (const [action, label] of cases) {
      db.exec("DELETE FROM reviewed_commits; DELETE FROM summary_comments; DELETE FROM review_runs")
      const { client, calls } = fakeClient()

      await processReviewJob(
        { ...payload, action },
        {
          getClient: async () => client,
          generateReview: async () => clean,
        },
      )

      expect(calls.comments[0]).toContain(`| ${label} |`)
    }
  })

  test("does not mark a clean review as done when the summary comment fails", async () => {
    const { client, calls } = fakeClient({
      createIssueComment: async () => {
        throw { status: 500 }
      },
    })

    await expect(
      processReviewJob(payload, {
        getClient: async () => client,
        generateReview: async () => clean,
      }),
    ).rejects.toEqual({ status: 500 })

    expect(calls.reviews).toHaveLength(0)
    expect(hasReviewed(payload.repo, payload.prNumber, payload.headSha!)).toBe(false)
    expect(
      countReviewRuns({
        repo: payload.repo,
        prNumber: payload.prNumber,
        kind: "auto",
        since: Date.now() - 60_000,
      }),
    ).toBe(0)
  })

  test("does not review the same head sha twice", async () => {
    const { client, calls } = fakeClient()

    await processReviewJob(payload, {
      getClient: async () => client,
      generateReview: async () => generated,
    })
    await processReviewJob(payload, {
      getClient: async () => client,
      generateReview: async () => generated,
    })

    expect(calls.reviews).toHaveLength(1)
    expect(calls.comments).toHaveLength(1)
  })

  test("skips stale commits", async () => {
    const { client, calls } = fakeClient({
      getPullRequest: async () => ({ ...pr, headSha: "other" }),
    })

    await processReviewJob(payload, {
      getClient: async () => client,
      generateReview: async () => generated,
    })

    expect(calls.reviews).toHaveLength(0)
    expect(hasReviewed(payload.repo, payload.prNumber, payload.headSha!)).toBe(false)
  })

  test("skips draft pull requests for automatic reviews without checks or comments", async () => {
    const { client, calls } = fakeClient({
      getPullRequest: async () => ({ ...pr, draft: true }),
    })

    await processReviewJob(payload, {
      getClient: async () => client,
      generateReview: async () => generated,
    })

    expect(calls.reviews).toHaveLength(0)
    expect(calls.comments).toHaveLength(0)
    expect(calls.checks).toHaveLength(0)
  })

  test("skips closed pull requests", async () => {
    const { client, calls } = fakeClient({
      getPullRequest: async () => ({ ...pr, state: "closed" }),
    })

    await processReviewJob(payload, {
      getClient: async () => client,
      generateReview: async () => generated,
    })

    expect(calls.reviews).toHaveLength(0)
    expect(calls.checks).toHaveLength(0)
  })

  test("runs an explicit /review on a draft pull request", async () => {
    const { client, calls } = fakeClient({
      getPullRequest: async () => ({ ...pr, draft: true }),
    })

    await processReviewJob(
      { ...payload, action: "manual", force: true },
      {
        getClient: async () => client,
        generateReview: async () => clean,
      },
    )

    expect(calls.comments).toHaveLength(1)
    expect(calls.checks).toHaveLength(1)
    expect(hasReviewed(payload.repo, payload.prNumber, payload.headSha!)).toBe(true)
  })

  test("uses the compare API for synchronize after a prior review", async () => {
    markReviewed({
      repo: payload.repo,
      prNumber: payload.prNumber,
      headSha: "oldsha00001",
      reviewId: 1,
    })

    const incrementalDiff = `diff --git a/src/a.ts b/src/a.ts
--- a/src/a.ts
+++ b/src/a.ts
@@ -1,1 +1,1 @@
-const b = 2
+const b = 3
`
    let generateMode: string | undefined
    const { client, calls } = fakeClient({
      compareCommits: async (_repo, base, head) => {
        calls.compares.push({ base, head })
        return { status: "ahead", aheadBy: 1, behindBy: 0, diff: incrementalDiff }
      },
      getPullRequestDiff: async () => {
        throw new Error("full diff should not be fetched")
      },
    })

    await processReviewJob(
      { ...payload, action: "synchronize", headSha: pr.headSha },
      {
        getClient: async () => client,
        generateReview: async (input) => {
          generateMode = input.mode
          return {
            ...clean,
            clipped: {
              diff: incrementalDiff,
              truncated: false,
              originalChars: incrementalDiff.length,
            },
          }
        },
      },
    )

    expect(calls.compares).toEqual([{ base: "oldsha00001", head: pr.headSha }])
    expect(generateMode).toBe("incremental")
    expect(calls.comments[0]).toContain("no new issues")
    expect(getLastReviewedSha(payload.repo, payload.prNumber)).toBe(pr.headSha)
  })

  test("falls back to the full diff when compare reports a force-push", async () => {
    markReviewed({
      repo: payload.repo,
      prNumber: payload.prNumber,
      headSha: "oldsha00001",
      reviewId: 1,
    })

    let generateMode: string | undefined
    const { client, calls } = fakeClient({
      compareCommits: async (_repo, base, head) => {
        calls.compares.push({ base, head })
        return { status: "diverged", aheadBy: 1, behindBy: 2, diff: "" }
      },
    })

    await processReviewJob(
      { ...payload, action: "synchronize" },
      {
        getClient: async () => client,
        generateReview: async (input) => {
          generateMode = input.mode
          return clean
        },
      },
    )

    expect(calls.compares).toHaveLength(1)
    expect(generateMode).toBe("full")
  })

  test("ready_for_review uses a full diff even if a prior SHA exists", async () => {
    markReviewed({
      repo: payload.repo,
      prNumber: payload.prNumber,
      headSha: "oldsha00001",
      reviewId: 1,
    })

    let generateMode: string | undefined
    const { client, calls } = fakeClient()

    await processReviewJob(
      { ...payload, action: "ready_for_review", headSha: "newsha00002", force: false },
      {
        getClient: async () =>
          ({
            ...client,
            getPullRequest: async () => ({ ...pr, headSha: "newsha00002" }),
          }) as ReviewGitHubClient,
        generateReview: async (input) => {
          generateMode = input.mode
          return clean
        },
      },
    )

    expect(calls.compares).toHaveLength(0)
    expect(generateMode).toBe("full")
  })

  test("auto-resolves fixed prior threads from the model result", async () => {
    const { client, calls } = fakeClient()

    await processReviewJob(payload, {
      getClient: async () => client,
      generateReview: async () => ({
        ...clean,
        result: {
          summary: "Fixed prior issue.",
          verdict: "looks_good",
          findings: [],
          fixedThreadIds: ["PRRT_1"],
        },
      }),
    })

    expect(calls.resolvedThreads).toEqual(["PRRT_1"])
    expect(calls.comments[0]).toContain("Resolved 1 prior review thread")
  })

  test("emits suggestion blocks on inline comments", async () => {
    const { client, calls } = fakeClient()

    await processReviewJob(payload, {
      getClient: async () => client,
      generateReview: async () => ({
        ...generated,
        result: {
          summary: "Fix it.",
          verdict: "needs_changes",
          findings: [
            {
              path: "src/a.ts",
              line: 1,
              side: "RIGHT",
              severity: "high",
              title: "Use const",
              body: "Prefer const.",
              suggestion: "const a = 1",
            },
          ],
        },
      }),
    })

    expect(calls.reviews[0]?.comments[0]?.body).toContain("```suggestion")
    expect(calls.reviews[0]?.comments[0]?.body).toContain("const a = 1")
  })

  test("stops automatic reviews after the max rounds with a one-time note", async () => {
    config.reviewAutoMaxRounds = 2
    incrementAutoReviewRounds(payload.repo, payload.prNumber)
    incrementAutoReviewRounds(payload.repo, payload.prNumber)

    const { client, calls } = fakeClient()

    await processReviewJob(payload, {
      getClient: async () => client,
      generateReview: async () => generated,
    })
    await processReviewJob(
      { ...payload, headSha: "another0001" },
      {
        getClient: async () =>
          ({
            ...client,
            getPullRequest: async () => ({ ...pr, headSha: "another0001" }),
          }) as ReviewGitHubClient,
        generateReview: async () => generated,
      },
    )

    expect(calls.reviews).toHaveLength(0)
    expect(calls.comments).toHaveLength(1)
    expect(calls.comments[0]).toContain("Automatic reviews paused")
    expect(calls.checks).toHaveLength(0)
    expect(getAutoReviewRounds(payload.repo, payload.prNumber)).toBe(2)
  })

  test("manual /review still works after the max automatic rounds", async () => {
    config.reviewAutoMaxRounds = 1
    incrementAutoReviewRounds(payload.repo, payload.prNumber)

    const { client, calls } = fakeClient()

    await processReviewJob(
      { ...payload, action: "manual", force: true },
      {
        getClient: async () => client,
        generateReview: async () => clean,
      },
    )

    expect(calls.comments.length + calls.updates.length).toBeGreaterThan(0)
    expect(calls.checks).toHaveLength(1)
  })

  test("counts quota only after a successful publish", async () => {
    const { client } = fakeClient({
      createIssueComment: async () => {
        throw { status: 500 }
      },
    })

    await expect(
      processReviewJob(payload, {
        getClient: async () => client,
        generateReview: async () => clean,
      }),
    ).rejects.toEqual({ status: 500 })

    expect(
      countReviewRuns({
        repo: payload.repo,
        prNumber: payload.prNumber,
        since: Date.now() - 60_000,
      }),
    ).toBe(0)
  })

  test("updates an existing summary comment instead of creating a new one", async () => {
    setSummaryCommentId(payload.repo, payload.prNumber, 55)
    const { client, calls } = fakeClient()

    await processReviewJob(payload, {
      getClient: async () => client,
      generateReview: async () => generated,
    })

    expect(calls.updates).toHaveLength(1)
    expect(calls.updates[0]?.id).toBe(55)
    expect(calls.comments).toHaveLength(0)
    expect(getSummaryCommentId(payload.repo, payload.prNumber)).toBe(55)
  })

  test("retries without inline comments when GitHub rejects anchors", async () => {
    let reviews = 0
    const { client, calls } = fakeClient({
      createReview: async (_repo, _pr, input) => {
        calls.reviews.push(input)
        reviews += 1
        if (reviews === 1) throw { status: 422 }
        return { id: 1, html_url: "https://github.com/review/1" }
      },
    })

    await processReviewJob(payload, {
      getClient: async () => client,
      generateReview: async () => generated,
    })

    expect(calls.reviews).toHaveLength(2)
    expect(calls.reviews[1]?.comments).toHaveLength(0)
    expect(calls.reviews[1]?.body).toContain("Some inline comments could not be anchored")
  })

  test("forces a new review for the same sha on manual commands", async () => {
    const { client, calls } = fakeClient()

    await processReviewJob(payload, {
      getClient: async () => client,
      generateReview: async () => generated,
    })

    await processReviewJob(
      { ...payload, headSha: "", action: "manual", force: true },
      {
        getClient: async () => client,
        generateReview: async () => generated,
      },
    )

    expect(calls.reviews).toHaveLength(2)
  })

  test("blocks automatic reviews when the per-PR 24h limit is reached", async () => {
    config.reviewAutoMaxPerPr24h = 2
    seedRuns({ kind: "auto", count: 2 })

    let aiCalls = 0
    const { client, calls } = fakeClient()

    await processReviewJob(payload, {
      getClient: async () => client,
      generateReview: async () => {
        aiCalls += 1
        return generated
      },
    })

    expect(aiCalls).toBe(0)
    expect(calls.reviews).toHaveLength(0)
    expect(calls.comments).toHaveLength(1)
    expect(
      countReviewRuns({
        repo: payload.repo,
        prNumber: payload.prNumber,
        kind: "auto",
        since: Date.now() - 24 * 60 * 60 * 1000,
      }),
    ).toBe(2)
  })

  test("refuses a manual review during the cooldown window", async () => {
    recordReviewRun({
      repo: payload.repo,
      prNumber: payload.prNumber,
      kind: "manual",
      createdAt: Date.now() - 1_000,
    })

    let aiCalls = 0
    const { client, calls } = fakeClient()

    await processReviewJob(
      { ...payload, headSha: "", action: "manual", force: true },
      {
        getClient: async () => client,
        generateReview: async () => {
          aiCalls += 1
          return generated
        },
      },
    )

    expect(aiCalls).toBe(0)
    expect(calls.reviews).toHaveLength(0)
    expect(calls.comments).toHaveLength(1)
  })

  test("blocks manual reviews when the per-PR 24h limit is reached", async () => {
    config.reviewManualCooldownSeconds = 0
    config.reviewManualMaxPerPr24h = 2
    seedRuns({ kind: "manual", count: 2 })

    let aiCalls = 0
    const { client, calls } = fakeClient()

    await processReviewJob(
      { ...payload, headSha: "", action: "manual", force: true },
      {
        getClient: async () => client,
        generateReview: async () => {
          aiCalls += 1
          return generated
        },
      },
    )

    expect(aiCalls).toBe(0)
    expect(calls.reviews).toHaveLength(0)
    expect(calls.comments).toHaveLength(1)
  })

  test("blocks reviews when the global 24h limit is reached", async () => {
    config.reviewGlobalMax24h = 2
    seedRuns({ repo: "other/repo", prNumber: 7, kind: "auto", count: 2 })

    let aiCalls = 0
    const { client, calls } = fakeClient()

    await processReviewJob(payload, {
      getClient: async () => client,
      generateReview: async () => {
        aiCalls += 1
        return generated
      },
    })

    expect(aiCalls).toBe(0)
    expect(calls.reviews).toHaveLength(0)
    expect(calls.comments).toHaveLength(1)
    expect(calls.comments[0]).toContain("global daily review limit")
    expect(calls.comments[0]).not.toContain("this pull request")
  })

  test("allows reviews when a limit is disabled with 0", async () => {
    config.reviewAutoMaxPerPr24h = 0
    seedRuns({ kind: "auto", count: 10 })

    const { client, calls } = fakeClient()

    await processReviewJob(payload, {
      getClient: async () => client,
      generateReview: async () => generated,
    })

    expect(calls.reviews).toHaveLength(1)
    expect(
      countReviewRuns({
        repo: payload.repo,
        prNumber: payload.prNumber,
        kind: "auto",
        since: Date.now() - 24 * 60 * 60 * 1000,
      }),
    ).toBe(11)
  })

  test("posts the rate limit notice only once per PR per 24h", async () => {
    config.reviewAutoMaxPerPr24h = 1
    seedRuns({ kind: "auto", count: 1 })

    let aiCalls = 0
    const { client, calls } = fakeClient()

    for (let run = 0; run < 2; run += 1) {
      await processReviewJob(payload, {
        getClient: async () => client,
        generateReview: async () => {
          aiCalls += 1
          return generated
        },
      })
    }

    expect(aiCalls).toBe(0)
    expect(calls.reviews).toHaveLength(0)
    expect(calls.comments).toHaveLength(1)
  })
})
