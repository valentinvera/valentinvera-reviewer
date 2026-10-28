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
