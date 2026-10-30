import { db } from "../db"

export function hasReviewed(repo: string, prNumber: number, headSha: string): boolean {
  const row = db
    .query<{ ok: number }, [string, number, string]>(`
      SELECT 1 AS ok FROM reviewed_commits
      WHERE repo = ? AND pr_number = ? AND head_sha = ?
    `)
    .get(repo, prNumber, headSha)

  return row !== null
}

export function markReviewed(input: {
  repo: string
  prNumber: number
  headSha: string
  reviewId: number | null
}): void {
  db.query<null, [string, number, string, number | null, number]>(`
    INSERT OR REPLACE INTO reviewed_commits (repo, pr_number, head_sha, review_id, reviewed_at)
    VALUES (?, ?, ?, ?, ?)
  `).run(input.repo, input.prNumber, input.headSha, input.reviewId, Date.now())
}

export function getSummaryCommentId(repo: string, prNumber: number): number | null {
  const row = db
    .query<{ comment_id: number }, [string, number]>(`
      SELECT comment_id FROM summary_comments
      WHERE repo = ? AND pr_number = ?
    `)
    .get(repo, prNumber)

  return row?.comment_id ?? null
}

export function setSummaryCommentId(repo: string, prNumber: number, commentId: number): void {
  db.query<null, [string, number, number, number]>(`
    INSERT OR REPLACE INTO summary_comments (repo, pr_number, comment_id, updated_at)
    VALUES (?, ?, ?, ?)
  `).run(repo, prNumber, commentId, Date.now())
}

export function clearSummaryCommentId(repo: string, prNumber: number): void {
  db.query<null, [string, number]>(`
    DELETE FROM summary_comments WHERE repo = ? AND pr_number = ?
  `).run(repo, prNumber)
}

export type ReviewRunKind = "auto" | "manual"

export function recordReviewRun(input: {
  repo: string
  prNumber: number
  kind: ReviewRunKind
  createdAt?: number
}): void {
  db.query<null, [string, number, string, number]>(`
    INSERT INTO review_runs (repo, pr_number, kind, created_at)
    VALUES (?, ?, ?, ?)
  `).run(input.repo, input.prNumber, input.kind, input.createdAt ?? Date.now())
}

export function countReviewRuns(input: {
  since: number
  repo?: string
  prNumber?: number
  kind?: ReviewRunKind
}): number {
  const clauses = ["created_at >= ?"]
  const params: Array<string | number> = [input.since]

  if (input.repo !== undefined) {
    clauses.push("repo = ?")
    params.push(input.repo)
  }
  if (input.prNumber !== undefined) {
    clauses.push("pr_number = ?")
    params.push(input.prNumber)
  }
  if (input.kind !== undefined) {
    clauses.push("kind = ?")
    params.push(input.kind)
  }

  const row = db
    .query<{ count: number }, Array<string | number>>(`
      SELECT COUNT(*) AS count FROM review_runs
      WHERE ${clauses.join(" AND ")}
    `)
    .get(...params)

  return row?.count ?? 0
}

export function getLastReviewRunAt(
  repo: string,
  prNumber: number,
  kind: ReviewRunKind,
): number | null {
  const row = db
    .query<{ created_at: number }, [string, number, string]>(`
      SELECT created_at FROM review_runs
      WHERE repo = ? AND pr_number = ? AND kind = ?
      ORDER BY created_at DESC
      LIMIT 1
    `)
    .get(repo, prNumber, kind)

  return row?.created_at ?? null
}

export function getRateLimitNoticeAt(repo: string, prNumber: number): number | null {
  const row = db
    .query<{ posted_at: number }, [string, number]>(`
      SELECT posted_at FROM review_rate_limit_notices
      WHERE repo = ? AND pr_number = ?
    `)
    .get(repo, prNumber)

  return row?.posted_at ?? null
}

export function markRateLimitNotice(repo: string, prNumber: number, postedAt: number): void {
  db.query<null, [string, number, number]>(`
    INSERT OR REPLACE INTO review_rate_limit_notices (repo, pr_number, posted_at)
    VALUES (?, ?, ?)
  `).run(repo, prNumber, postedAt)
}
