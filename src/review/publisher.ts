import type { Octokit } from "octokit"
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
}

export interface CreateReviewInput {
  commitId: string
  body: string
  comments: ReviewCommentInput[]
}

export interface ReviewGitHubClient {
  getPullRequest(repo: string, prNumber: number): Promise<PullRequestForReview>
  getPullRequestDiff(repo: string, prNumber: number): Promise<string>
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
      comments: input.comments,
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
