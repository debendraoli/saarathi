-- saarathi-notify owns the in-app notification inbox. Applied idempotently at
-- startup (no migration files — single embedded source of truth).
CREATE TABLE IF NOT EXISTS notifications (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid        NOT NULL,
    class      text        NOT NULL,   -- safety | transactional | compliance | marketing
    title      text        NOT NULL,
    body       text,
    channel    text        NOT NULL DEFAULT 'inapp',
    read_at    timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS notifications_user_idx ON notifications (user_id, created_at DESC);
