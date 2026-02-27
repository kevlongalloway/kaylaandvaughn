-- Idempotent schema — safe to run on every server startup.
-- All statements use IF NOT EXISTS so restarts never fail.

CREATE TABLE IF NOT EXISTS rsvps (
  id            SERIAL PRIMARY KEY,
  first_name    TEXT        NOT NULL,
  last_name     TEXT        NOT NULL,
  email         TEXT,
  song_request  TEXT,
  submitted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS rsvps_submitted_at_idx ON rsvps (submitted_at DESC);

-- Single-row admin credentials table.
-- The CHECK constraint enforces only one row ever exists.
CREATE TABLE IF NOT EXISTS admin_credentials (
  id            INTEGER PRIMARY KEY DEFAULT 1,
  password_hash TEXT        NOT NULL,
  CHECK (id = 1)
);
