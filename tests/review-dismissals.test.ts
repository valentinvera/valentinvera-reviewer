import { beforeEach, describe, expect, test } from "bun:test"
import { db } from "../src/db"
import {
  DISMISSAL_REPLY_RE,
  learnAndResolveFromReply,
  learnDismissalsFromReactions,
} from "../src/review/dismissals"
import type { ReviewGitHubClient } from "../src/review/publisher"
import { listLearnedDismissals } from "../src/review/store"

beforeEach(() => {
  db.exec("DELETE FROM learned_dismissals")
})

describe("DISMISSAL_REPLY_RE", () => {
  test("matches English and Spanish dismissal phrases", () => {
    expect(DISMISSAL_REPLY_RE.test("not an issue")).toBe(true)
    expect(DISMISSAL_REPLY_RE.test("No es un issue")).toBe(true)
    expect(DISMISSAL_REPLY_RE.test("false positive")).toBe(true)
    expect(DISMISSAL_REPLY_RE.test("looks fine")).toBe(false)
  })
})

describe("learnAndResolveFromReply", () => {
  test("stores a dismissal and resolves the parent thread", async () => {
    const resolved: string[] = []
    const client = {
      getPullRequestReviewComment: async () => ({
        id: 11,
        body: "**🟠 high · Bug**\n\nDetails",
        path: "src/a.ts",
        line: 1,
        originalLine: 1,
        user: "valentinvera-reviewer[bot]",
        inReplyToId: null,
        htmlUrl: "https://example.com",
      }),
      listReviewThreads: async () => [
        {
          id: "PRRT_9",
          isResolved: false,
          path: "src/a.ts",
          line: 1,
          comments: [
            {
              id: 11,
              body: "**🟠 high · Bug**\n\nDetails",
              path: "src/a.ts",
              line: 1,
              author: "valentinvera-reviewer[bot]",
              createdAt: "2026-01-01T00:00:00Z",
              isBot: true,
            },
          ],
        },
      ],
      resolveReviewThread: async (id: string) => {
        resolved.push(id)
      },
    } as unknown as ReviewGitHubClient

    const learned = await learnAndResolveFromReply({
      client,
      repo: "o/r",
      prNumber: 1,
      replyBody: "not an issue",
      parentCommentId: 11,
    })

    expect(learned).toBe(true)
    expect(resolved).toEqual(["PRRT_9"])
    expect(listLearnedDismissals("o/r")[0]?.title).toBe("Bug")
  })
})

describe("learnDismissalsFromReactions", () => {
  test("learns from thumbs-down reactions", async () => {
    const resolved: string[] = []
    const client = {
      listReviewThreads: async () => [
        {
          id: "PRRT_1",
          isResolved: false,
          path: "src/a.ts",
          line: 1,
          comments: [
            {
              id: 5,
              body: "**🟡 medium · Nit**\n\nBody",
              path: "src/a.ts",
              line: 1,
              author: "valentinvera-reviewer[bot]",
              createdAt: "2026-01-01T00:00:00Z",
              isBot: true,
            },
          ],
        },
      ],
      listCommentReactions: async () => [{ content: "-1", user: "valen" }],
      resolveReviewThread: async (id: string) => {
        resolved.push(id)
      },
    } as unknown as ReviewGitHubClient

    expect(await learnDismissalsFromReactions({ client, repo: "o/r", prNumber: 1 })).toBe(1)
    expect(resolved).toEqual(["PRRT_1"])
    expect(listLearnedDismissals("o/r")[0]?.reason).toBe("thumbs_down")
  })
})
