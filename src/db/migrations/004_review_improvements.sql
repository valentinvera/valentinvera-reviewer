-- Lifetime count of successful automatic reviews per pull request.
CREATE TABLE IF NOT EXISTS review_auto_rounds (
  repo                   TEXT    NOT NULL,
  pr_number              INTEGER NOT NULL,
  rounds                 INTEGER NOT NULL DEFAULT 0,
  max_rounds_notified_at INTEGER,
  PRIMARY KEY (repo, pr_number)
);

-- Issues humans dismissed so future reviews can avoid repeating them.
CREATE TABLE IF NOT EXISTS learned_dismissals (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  repo               TEXT    NOT NULL,
  path               TEXT,
  title              TEXT    NOT NULL,
  body               TEXT,
  reason             TEXT    NOT NULL,
  source_comment_id  INTEGER,
  created_at         INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS learned_dismissals_repo_created_idx
  ON learned_dismissals (repo, created_at DESC);

-- In-flight review generation for a PR (superseded when a newer push arrives).
CREATE TABLE IF NOT EXISTS active_reviews (
  repo           TEXT    NOT NULL,
  pr_number      INTEGER NOT NULL,
  generation_id  TEXT    NOT NULL,
  head_sha       TEXT    NOT NULL,
  check_run_id   INTEGER,
  started_at     INTEGER NOT NULL,
  PRIMARY KEY (repo, pr_number)
);

-- Persistent failure notice comment (updated instead of spammed).
CREATE TABLE IF NOT EXISTS failure_comments (
  repo        TEXT    NOT NULL,
  pr_number   INTEGER NOT NULL,
  comment_id  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  PRIMARY KEY (repo, pr_number)
);
