import { beforeEach, describe, expect, test } from "bun:test"
import { db } from "../src/db"
import type { GeneratedReview } from "../src/review/engine"
import { processReviewJob, type ReviewJobPayload } from "../src/review/handler"
import type {
  CreateReviewInput,
  PullRequestForReview,
  ReviewGitHubClient,
} from "../src/review/publisher"
import { getSummaryCommentId, hasReviewed, setSummaryCommentId } from "../src/review/store"

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
    summary: "Resumen",
    verdict: "needs_changes",
    findings: [
      {
        path: "src/a.ts",
        line: 1,
        side: "RIGHT",
        severity: "high",
        title: "Uno",
        body: "Body",
      },
      {
        path: "src/a.ts",
        line: 99,
        side: "RIGHT",
        severity: "low",
        title: "Dos",
        body: "Body2",
      },
    ],
  },
  clipped: { diff, truncated: false, originalChars: diff.length },
  model: "mock-model",
  durationMs: 1,
  usage: undefined,
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
}

function fakeClient(overrides: Partial<ReviewGitHubClient> = {}) {
  const calls: Calls = { reviews: [], comments: [], updates: [] }

  const client: ReviewGitHubClient = {
    getPullRequest: async () => pr,
    getPullRequestDiff: async () => diff,
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

beforeEach(() => {
  db.exec("DELETE FROM reviewed_commits; DELETE FROM summary_comments")
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
    expect(calls.reviews[0]?.body).toContain("Observaciones generales")
    expect(calls.reviews[0]?.body).toContain("Dos")
    expect(calls.reviews[0]?.body).toContain("Review automático")
    expect(calls.comments).toHaveLength(1)
    expect(calls.comments[0]).toContain("valentinvera-reviewer")
    expect(hasReviewed(payload.repo, payload.prNumber, payload.headSha)).toBe(true)
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
    expect(hasReviewed(payload.repo, payload.prNumber, payload.headSha)).toBe(false)
  })

  test("skips drafts and closed pull requests", async () => {
    for (const override of [{ draft: true }, { state: "closed" as const }]) {
      db.exec("DELETE FROM reviewed_commits; DELETE FROM summary_comments")
      const { client, calls } = fakeClient({
        getPullRequest: async () => ({ ...pr, ...override }),
      })

      await processReviewJob(payload, {
        getClient: async () => client,
        generateReview: async () => generated,
      })

      expect(calls.reviews).toHaveLength(0)
    }
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
    expect(calls.reviews[1]?.body).toContain("comentarios inline")
  })
})
