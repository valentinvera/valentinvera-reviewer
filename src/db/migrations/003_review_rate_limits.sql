CREATE TABLE IF NOT EXISTS review_runs (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  repo        TEXT    NOT NULL,
  pr_number   INTEGER NOT NULL,
  kind        TEXT    NOT NULL CHECK (kind IN ('auto', 'manual')),
  created_at  INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS review_runs_repo_pr_kind_created_idx
  ON review_runs (repo, pr_number, kind, created_at);

CREATE INDEX IF NOT EXISTS review_runs_created_idx
  ON review_runs (created_at);

CREATE TABLE IF NOT EXISTS review_rate_limit_notices (
  repo        TEXT    NOT NULL,
  pr_number   INTEGER NOT NULL,
  posted_at   INTEGER NOT NULL,
  PRIMARY KEY (repo, pr_number)
);
