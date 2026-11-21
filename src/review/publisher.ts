import type { Octokit } from "octokit"
import { config } from "../config"
import { getGitHubApp } from "../github"
import type { ReviewPullRequest } from "./prompt"

export interface PullRequestForReview extends ReviewPullRequest {
  state: "open" | "closed"
  draft: boolean
  htmlUrl: string
}

export interface ReviewCommentInput {
  path: string
  line: number
  side: "RIGHT" | "LEFT"
  body: string
  /** First line of a multi-line comment / suggestion range. */
  startLine?: number
}

export interface CreateReviewInput {
  commitId: string
  body: string
  comments: ReviewCommentInput[]
}

export interface CompareCommitsResult {
  status: string
  aheadBy: number
  behindBy: number
  diff: string
}

export type CheckRunConclusion = "success" | "failure" | "neutral" | "cancelled" | "timed_out"

export interface CheckRunInput {
  name: string
  headSha: string
  status: "queued" | "in_progress" | "completed"
  conclusion?: CheckRunConclusion
  title?: string
  summary?: string
  text?: string
}

export interface ReviewThreadComment {
  id: number
  body: string
  path: string | null
  line: number | null
  author: string
  createdAt: string
  isBot: boolean
}

export interface ReviewThread {
  id: string
  isResolved: boolean
  path: string | null
  line: number | null
  comments: ReviewThreadComment[]
}

export interface PullRequestReviewComment {
  id: number
  body: string
  path: string
  line: number | null
  originalLine: number | null
  user: string
  inReplyToId: number | null
  htmlUrl: string
}

export interface ReviewGitHubClient {
  getPullRequest(repo: string, prNumber: number): Promise<PullRequestForReview>
  getPullRequestDiff(repo: string, prNumber: number): Promise<string>
  compareCommits(repo: string, base: string, head: string): Promise<CompareCommitsResult>
  getFileContent(repo: string, path: string, ref: string): Promise<string | null>
  listReviewThreads(repo: string, prNumber: number): Promise<ReviewThread[]>
  resolveReviewThread(threadId: string): Promise<void>
  getPullRequestReviewComment(repo: string, commentId: number): Promise<PullRequestReviewComment>
  listCommentReactions(
    repo: string,
    commentId: number,
  ): Promise<Array<{ content: string; user: string }>>
  createCheckRun(repo: string, input: CheckRunInput): Promise<{ id: number }>
  updateCheckRun(
    repo: string,
    checkRunId: number,
    input: Omit<CheckRunInput, "name" | "headSha"> & { name?: string; headSha?: string },
  ): Promise<{ id: number }>
  createReview(
    repo: string,
    prNumber: number,
    input: CreateReviewInput,
  ): Promise<{ id: number; html_url: string }>
  createIssueComment(repo: string, prNumber: number, body: string): Promise<{ id: number }>
  updateIssueComment(repo: string, commentId: number, body: string): Promise<{ id: number }>
}

function splitRepo(repo: string): { owner: string; name: string } {
  const [owner, name] = repo.split("/")
  if (!owner || !name) throw new Error(`Invalid repository: ${repo}`)
  return { owner, name }
}

export function isGitHubStatus(error: unknown, status: number): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "status" in error &&
    (error as { status?: number }).status === status
  )
}

const REVIEW_THREADS_QUERY = `
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        reviewThreads(first: 100) {
          nodes {
            id
            isResolved
            comments(first: 30) {
              nodes {
                databaseId
                body
                path
                line
                createdAt
                author {
                  login
                  __typename
                }
              }
            }
          }
        }
      }
    }
  }
`

const RESOLVE_THREAD_MUTATION = `
  mutation($threadId: ID!) {
    resolveReviewThread(input: { threadId: $threadId }) {
      thread { id isResolved }
    }
  }
`

export class OctokitReviewClient implements ReviewGitHubClient {
  constructor(private readonly octokit: Octokit) {}

  async getPullRequest(repo: string, prNumber: number): Promise<PullRequestForReview> {
    const { owner, name } = splitRepo(repo)
    const { data } = await this.octokit.rest.pulls.get({
      owner,
      repo: name,
      pull_number: prNumber,
    })

    return {
      number: data.number,
      title: data.title,
      body: data.body,
      author: data.user?.login ?? "unknown",
      baseRef: data.base.ref,
      headRef: data.head.ref,
      baseSha: data.base.sha,
      headSha: data.head.sha,
      changedFiles: data.changed_files,
      additions: data.additions,
      deletions: data.deletions,
      state: data.state === "closed" ? "closed" : "open",
      draft: data.draft ?? false,
      htmlUrl: data.html_url,
    }
  }

  async getPullRequestDiff(repo: string, prNumber: number): Promise<string> {
    const { owner, name } = splitRepo(repo)
    const response = await this.octokit.rest.pulls.get({
      owner,
      repo: name,
      pull_number: prNumber,
      mediaType: { format: "diff" },
    })

    return response.data as unknown as string
  }

  async compareCommits(repo: string, base: string, head: string): Promise<CompareCommitsResult> {
    const { owner, name } = splitRepo(repo)
    const response = await this.octokit.rest.repos.compareCommitsWithBasehead({
      owner,
      repo: name,
      basehead: `${base}...${head}`,
      mediaType: { format: "diff" },
    })

    // When requesting the diff media type, Octokit returns the raw patch string.
    if (typeof response.data === "string") {
      return {
        status: "comparable",
        aheadBy: 0,
        behindBy: 0,
        diff: response.data,
      }
    }

    const data = response.data as {
      status?: string
      ahead_by?: number
      behind_by?: number
      files?: Array<{ patch?: string; filename?: string; status?: string }>
    }

    const fileDiffs = (data.files ?? [])
      .map((file) => {
        if (!file.patch || !file.filename) return ""
        const header = [
          `diff --git a/${file.filename} b/${file.filename}`,
          `--- a/${file.filename}`,
          `+++ b/${file.filename}`,
        ].join("\n")
        return `${header}\n${file.patch}`
      })
      .filter(Boolean)

    return {
      status: data.status ?? "unknown",
      aheadBy: data.ahead_by ?? 0,
      behindBy: data.behind_by ?? 0,
      diff: fileDiffs.join("\n"),
    }
  }

  async getFileContent(repo: string, path: string, ref: string): Promise<string | null> {
    const { owner, name } = splitRepo(repo)

    try {
      const { data } = await this.octokit.rest.repos.getContent({
        owner,
        repo: name,
        path,
        ref,
      })

      if (Array.isArray(data) || data.type !== "file" || !("content" in data) || !data.content) {
        return null
      }

      return Buffer.from(data.content, data.encoding === "base64" ? "base64" : "utf8").toString(
        "utf8",
      )
    } catch (error) {
      if (isGitHubStatus(error, 404)) return null
      throw error
    }
  }

  async listReviewThreads(repo: string, prNumber: number): Promise<ReviewThread[]> {
    const { owner, name } = splitRepo(repo)
    const response = await this.octokit.graphql<{
      repository: {
        pullRequest: {
          reviewThreads: {
            nodes: Array<{
              id: string
              isResolved: boolean
              comments: {
                nodes: Array<{
                  databaseId: number
                  body: string
                  path: string | null
                  line: number | null
                  createdAt: string
                  author: { login: string; __typename: string } | null
                }>
              }
            }>
          }
        } | null
      } | null
    }>(REVIEW_THREADS_QUERY, { owner, name, number: prNumber })

    const nodes = response.repository?.pullRequest?.reviewThreads.nodes ?? []

    return nodes.map((thread) => {
      const comments = thread.comments.nodes.map((comment) => ({
        id: comment.databaseId,
        body: comment.body,
        path: comment.path,
        line: comment.line,
        author: comment.author?.login ?? "unknown",
        createdAt: comment.createdAt,
        isBot: comment.author?.__typename === "Bot",
      }))

      const first = comments[0]

      return {
        id: thread.id,
        isResolved: thread.isResolved,
        path: first?.path ?? null,
        line: first?.line ?? null,
        comments,
      }
    })
  }

  async resolveReviewThread(threadId: string): Promise<void> {
    await this.octokit.graphql(RESOLVE_THREAD_MUTATION, { threadId })
  }

  async getPullRequestReviewComment(
    repo: string,
    commentId: number,
  ): Promise<PullRequestReviewComment> {
    const { owner, name } = splitRepo(repo)
    const { data } = await this.octokit.rest.pulls.getReviewComment({
      owner,
      repo: name,
      comment_id: commentId,
    })

    return {
      id: data.id,
      body: data.body,
      path: data.path,
      line: data.line ?? null,
      originalLine: data.original_line ?? null,
      user: data.user?.login ?? "unknown",
      inReplyToId: data.in_reply_to_id ?? null,
      htmlUrl: data.html_url,
    }
  }

  async listCommentReactions(
    repo: string,
    commentId: number,
  ): Promise<Array<{ content: string; user: string }>> {
    const { owner, name } = splitRepo(repo)
    const { data } = await this.octokit.rest.reactions.listForPullRequestReviewComment({
      owner,
      repo: name,
      comment_id: commentId,
    })

    return data.map((reaction) => ({
      content: reaction.content,
      user: reaction.user?.login ?? "unknown",
    }))
  }

  async createCheckRun(repo: string, input: CheckRunInput): Promise<{ id: number }> {
    const { owner, name } = splitRepo(repo)
    const { data } = await this.octokit.rest.checks.create({
      owner,
      repo: name,
      name: input.name,
      head_sha: input.headSha,
      status: input.status,
      ...(input.conclusion ? { conclusion: input.conclusion } : {}),
      ...(input.status === "completed" ? { completed_at: new Date().toISOString() } : {}),
      output: {
        title: input.title ?? input.name,
        summary: input.summary ?? "",
        ...(input.text ? { text: input.text } : {}),
      },
    })

    return { id: data.id }
  }

  async updateCheckRun(
    repo: string,
    checkRunId: number,
    input: Omit<CheckRunInput, "name" | "headSha"> & { name?: string; headSha?: string },
  ): Promise<{ id: number }> {
    const { owner, name } = splitRepo(repo)
    const { data } = await this.octokit.rest.checks.update({
      owner,
      repo: name,
      check_run_id: checkRunId,
      ...(input.name ? { name: input.name } : {}),
      status: input.status,
      ...(input.conclusion ? { conclusion: input.conclusion } : {}),
      ...(input.status === "completed" ? { completed_at: new Date().toISOString() } : {}),
      output: {
        title: input.title ?? config.reviewCheckName,
        summary: input.summary ?? "",
        ...(input.text ? { text: input.text } : {}),
      },
    })

    return { id: data.id }
  }

  async createReview(
    repo: string,
    prNumber: number,
    input: CreateReviewInput,
  ): Promise<{ id: number; html_url: string }> {
    const { owner, name } = splitRepo(repo)
    const { data } = await this.octokit.rest.pulls.createReview({
      owner,
      repo: name,
      pull_number: prNumber,
      commit_id: input.commitId,
      body: input.body,
      event: "COMMENT",
      comments: input.comments.map((comment) => ({
        path: comment.path,
        line: comment.line,
        side: comment.side,
        body: comment.body,
        ...(comment.startLine !== undefined
          ? { start_line: comment.startLine, start_side: comment.side }
          : {}),
      })),
    })

    return { id: data.id, html_url: data.html_url }
  }

  async createIssueComment(repo: string, prNumber: number, body: string): Promise<{ id: number }> {
    const { owner, name } = splitRepo(repo)
    const { data } = await this.octokit.rest.issues.createComment({
      owner,
      repo: name,
      issue_number: prNumber,
      body,
    })

    return { id: data.id }
  }

  async updateIssueComment(repo: string, commentId: number, body: string): Promise<{ id: number }> {
    const { owner, name } = splitRepo(repo)
    const { data } = await this.octokit.rest.issues.updateComment({
      owner,
      repo: name,
      comment_id: commentId,
      body,
    })

    return { id: data.id }
  }
}

export async function getInstallationClient(installationId: number): Promise<ReviewGitHubClient> {
  const octokit = await getGitHubApp().getInstallationOctokit(installationId)
  return new OctokitReviewClient(octokit as unknown as Octokit)
}
