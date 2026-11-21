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

/** Most recently published review SHA for a pull request, if any. */
export function getLastReviewedSha(repo: string, prNumber: number): string | null {
  const row = db
    .query<{ head_sha: string }, [string, number]>(`
      SELECT head_sha FROM reviewed_commits
      WHERE repo = ? AND pr_number = ?
      ORDER BY reviewed_at DESC
      LIMIT 1
    `)
    .get(repo, prNumber)

  return row?.head_sha ?? null
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

export function getAutoReviewRounds(repo: string, prNumber: number): number {
  const row = db
    .query<{ rounds: number }, [string, number]>(`
      SELECT rounds FROM review_auto_rounds
      WHERE repo = ? AND pr_number = ?
    `)
    .get(repo, prNumber)

  return row?.rounds ?? 0
}

export function incrementAutoReviewRounds(repo: string, prNumber: number): number {
  db.query<null, [string, number]>(`
    INSERT INTO review_auto_rounds (repo, pr_number, rounds)
    VALUES (?, ?, 1)
    ON CONFLICT(repo, pr_number) DO UPDATE SET rounds = rounds + 1
  `).run(repo, prNumber)

  return getAutoReviewRounds(repo, prNumber)
}

export function getMaxRoundsNotifiedAt(repo: string, prNumber: number): number | null {
  const row = db
    .query<{ max_rounds_notified_at: number | null }, [string, number]>(`
      SELECT max_rounds_notified_at FROM review_auto_rounds
      WHERE repo = ? AND pr_number = ?
    `)
    .get(repo, prNumber)

  return row?.max_rounds_notified_at ?? null
}

export function markMaxRoundsNotified(repo: string, prNumber: number, at = Date.now()): void {
  db.query<null, [string, number, number]>(`
    INSERT INTO review_auto_rounds (repo, pr_number, rounds, max_rounds_notified_at)
    VALUES (?, ?, 0, ?)
    ON CONFLICT(repo, pr_number) DO UPDATE SET max_rounds_notified_at = excluded.max_rounds_notified_at
  `).run(repo, prNumber, at)
}

export interface LearnedDismissal {
  id: number
  repo: string
  path: string | null
  title: string
  body: string | null
  reason: string
  sourceCommentId: number | null
  createdAt: number
}

export function addLearnedDismissal(input: {
  repo: string
  path?: string | null
  title: string
  body?: string | null
  reason: string
  sourceCommentId?: number | null
  createdAt?: number
}): void {
  db.query<null, [string, string | null, string, string | null, string, number | null, number]>(`
    INSERT INTO learned_dismissals
      (repo, path, title, body, reason, source_comment_id, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `).run(
    input.repo,
    input.path ?? null,
    input.title,
    input.body ?? null,
    input.reason,
    input.sourceCommentId ?? null,
    input.createdAt ?? Date.now(),
  )
}

export function listLearnedDismissals(repo: string, limit = 50): LearnedDismissal[] {
  const rows = db
    .query<
      {
        id: number
        repo: string
        path: string | null
        title: string
        body: string | null
        reason: string
        source_comment_id: number | null
        created_at: number
      },
      [string, number]
    >(
      `
      SELECT id, repo, path, title, body, reason, source_comment_id, created_at
      FROM learned_dismissals
      WHERE repo = ?
      ORDER BY created_at DESC
      LIMIT ?
    `,
    )
    .all(repo, limit)

  return rows.map((row) => ({
    id: row.id,
    repo: row.repo,
    path: row.path,
    title: row.title,
    body: row.body,
    reason: row.reason,
    sourceCommentId: row.source_comment_id,
    createdAt: row.created_at,
  }))
}

export interface ActiveReview {
  generationId: string
  headSha: string
  checkRunId: number | null
  startedAt: number
}

export function beginActiveReview(input: {
  repo: string
  prNumber: number
  generationId: string
  headSha: string
  checkRunId?: number | null
}): void {
  db.query<null, [string, number, string, string, number | null, number]>(`
    INSERT OR REPLACE INTO active_reviews
      (repo, pr_number, generation_id, head_sha, check_run_id, started_at)
    VALUES (?, ?, ?, ?, ?, ?)
  `).run(
    input.repo,
    input.prNumber,
    input.generationId,
    input.headSha,
    input.checkRunId ?? null,
    Date.now(),
  )
}

export function setActiveReviewCheckRunId(
  repo: string,
  prNumber: number,
  checkRunId: number,
): void {
  db.query<null, [number, string, number]>(`
    UPDATE active_reviews SET check_run_id = ? WHERE repo = ? AND pr_number = ?
  `).run(checkRunId, repo, prNumber)
}

export function getActiveReview(repo: string, prNumber: number): ActiveReview | null {
  const row = db
    .query<
      {
        generation_id: string
        head_sha: string
        check_run_id: number | null
        started_at: number
      },
      [string, number]
    >(
      `
      SELECT generation_id, head_sha, check_run_id, started_at
      FROM active_reviews
      WHERE repo = ? AND pr_number = ?
    `,
    )
    .get(repo, prNumber)

  if (!row) return null

  return {
    generationId: row.generation_id,
    headSha: row.head_sha,
    checkRunId: row.check_run_id,
    startedAt: row.started_at,
  }
}

export function clearActiveReview(repo: string, prNumber: number, generationId?: string): void {
  if (generationId) {
    db.query<null, [string, number, string]>(`
      DELETE FROM active_reviews
      WHERE repo = ? AND pr_number = ? AND generation_id = ?
    `).run(repo, prNumber, generationId)
    return
  }

  db.query<null, [string, number]>(`
    DELETE FROM active_reviews WHERE repo = ? AND pr_number = ?
  `).run(repo, prNumber)
}

export function isActiveReview(repo: string, prNumber: number, generationId: string): boolean {
  const active = getActiveReview(repo, prNumber)
  return active?.generationId === generationId
}

export function getFailureCommentId(repo: string, prNumber: number): number | null {
  const row = db
    .query<{ comment_id: number }, [string, number]>(`
      SELECT comment_id FROM failure_comments
      WHERE repo = ? AND pr_number = ?
    `)
    .get(repo, prNumber)

  return row?.comment_id ?? null
}

export function setFailureCommentId(repo: string, prNumber: number, commentId: number): void {
  db.query<null, [string, number, number, number]>(`
    INSERT OR REPLACE INTO failure_comments (repo, pr_number, comment_id, updated_at)
    VALUES (?, ?, ?, ?)
  `).run(repo, prNumber, commentId, Date.now())
}

export function clearFailureCommentId(repo: string, prNumber: number): void {
  db.query<null, [string, number]>(`
    DELETE FROM failure_comments WHERE repo = ? AND pr_number = ?
  `).run(repo, prNumber)
}
