CREATE TABLE IF NOT EXISTS reviewed_commits (
  repo         TEXT    NOT NULL,
  pr_number    INTEGER NOT NULL,
  head_sha     TEXT    NOT NULL,
  review_id    INTEGER,
  reviewed_at  INTEGER NOT NULL,
  PRIMARY KEY (repo, pr_number, head_sha)
);

CREATE TABLE IF NOT EXISTS summary_comments (
  repo        TEXT    NOT NULL,
  pr_number   INTEGER NOT NULL,
  comment_id  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  PRIMARY KEY (repo, pr_number)
);
