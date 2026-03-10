-- Idempotent schema — safe to run on every server startup.
-- All statements use IF NOT EXISTS so restarts never fail.

CREATE TABLE IF NOT EXISTS rsvps (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  first_name    TEXT    NOT NULL,
  last_name     TEXT    NOT NULL,
  email         TEXT,
  song_request  TEXT,
  submitted_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS rsvps_submitted_at_idx ON rsvps (submitted_at DESC);

-- Single-row admin credentials table.
-- The CHECK constraint enforces only one row ever exists.
CREATE TABLE IF NOT EXISTS admin_credentials (
  id            INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  password_hash TEXT    NOT NULL
);
