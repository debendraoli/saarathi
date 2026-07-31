-- 0003_preferences.sql — per-user settings (default payment method, appearance)
-- and synced recent searches (so a rider's history/searches follow their account).

CREATE TABLE user_preferences (
    user_id                uuid        PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    default_payment_method text        NOT NULL DEFAULT 'cash',    -- cash | wallet
    theme                  text        NOT NULL DEFAULT 'system',  -- system | light | dark
    updated_at             timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE recent_searches (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    label      text        NOT NULL,
    address    text,
    lat        double precision,
    lng        double precision,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX recent_searches_user_idx ON recent_searches (user_id, created_at DESC);
