-- Waitlist schema. The app also applies this automatically on first use (CREATE TABLE IF NOT EXISTS).
CREATE TABLE IF NOT EXISTS waitlist (
  id          BIGSERIAL PRIMARY KEY,
  email       TEXT NOT NULL UNIQUE,
  role        TEXT NOT NULL CHECK (role IN ('trader', 'lp', 'both')),
  source      TEXT,
  ip_hash     TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
