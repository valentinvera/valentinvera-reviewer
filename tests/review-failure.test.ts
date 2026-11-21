import { beforeEach, describe, expect, test } from "bun:test"
import { db } from "../src/db"
import { reportFinalReviewFailure } from "../src/review/failure"
import type { ReviewGitHubClient } from "../src/review/publisher"
import { beginActiveReview, getFailureCommentId } from "../src/review/store"

beforeEach(() => {
  db.exec("DELETE FROM active_reviews; DELETE FROM failure_comments")
})

describe("reportFinalReviewFailure", () => {
  test("completes the check as failure and posts a retry comment", async () => {
    beginActiveReview({
      repo: "o/r",
      prNumber: 7,
      generationId: "gen-1",
      headSha: "abc",
      checkRunId: 55,
    })

    const updates: Array<{ id: number; conclusion?: string }> = []
    const comments: string[] = []

    const client = {
      getPullRequest: async () => ({
        number: 7,
        title: "t",
        body: null,
        author: "valen",
        baseRef: "main",
        headRef: "feat",
        baseSha: "b",
        headSha: "abc",
        changedFiles: 1,
        additions: 1,
        deletions: 0,
        state: "open",
        draft: false,
        htmlUrl: "https://example.com",
      }),
      updateCheckRun: async (_repo: string, id: number, input: { conclusion?: string }) => {
        updates.push({ id, conclusion: input.conclusion })
        return { id }
      },
      createIssueComment: async (_repo: string, _pr: number, body: string) => {
        comments.push(body)
        return { id: 99 }
      },
      updateIssueComment: async () => ({ id: 99 }),
      createCheckRun: async () => ({ id: 1 }),
    } as unknown as ReviewGitHubClient

    await reportFinalReviewFailure(
      {
        installationId: 1,
        repo: "o/r",
        prNumber: 7,
        headSha: "abc",
        action: "opened",
      },
      new Error("model timeout"),
      { getClient: async () => client },
    )

    expect(updates).toEqual([{ id: 55, conclusion: "failure" }])
    expect(comments[0]).toContain("`/review`")
    expect(getFailureCommentId("o/r", 7)).toBe(99)
  })

  test("stays silent for draft auto failures", async () => {
    let comments = 0
    const client = {
      getPullRequest: async () => ({
        number: 7,
        title: "t",
        body: null,
        author: "valen",
        baseRef: "main",
        headRef: "feat",
        baseSha: "b",
        headSha: "abc",
        changedFiles: 1,
        additions: 1,
        deletions: 0,
        state: "open",
        draft: true,
        htmlUrl: "https://example.com",
      }),
      createIssueComment: async () => {
        comments += 1
        return { id: 1 }
      },
      createCheckRun: async () => ({ id: 1 }),
      updateCheckRun: async () => ({ id: 1 }),
    } as unknown as ReviewGitHubClient

    await reportFinalReviewFailure(
      {
        installationId: 1,
        repo: "o/r",
        prNumber: 7,
        headSha: "abc",
        action: "opened",
      },
      new Error("boom"),
      { getClient: async () => client },
    )

    expect(comments).toBe(0)
  })
})
