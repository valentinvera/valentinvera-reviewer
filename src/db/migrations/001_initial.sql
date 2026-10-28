CREATE TABLE IF NOT EXISTS jobs (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  delivery_id   TEXT    NOT NULL UNIQUE,
  kind          TEXT    NOT NULL,
  payload       TEXT    NOT NULL,
  status        TEXT    NOT NULL DEFAULT 'queued',
  attempts      INTEGER NOT NULL DEFAULT 0,
  max_attempts  INTEGER NOT NULL DEFAULT 3,
  run_after     INTEGER NOT NULL DEFAULT 0,
  last_error    TEXT,
  created_at    INTEGER NOT NULL,
  started_at    INTEGER,
  finished_at   INTEGER
);

CREATE INDEX IF NOT EXISTS jobs_status_run_after_idx
  ON jobs (status, run_after, id);
