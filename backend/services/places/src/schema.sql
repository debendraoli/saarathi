-- saarathi-places owns community map contributions, the points ledger, and
-- contributor badges. Applied idempotently at startup (no migration files —
-- single embedded source of truth, same convention as every other service).

DO $$ BEGIN
    CREATE TYPE place_category AS ENUM
        ('organisation', 'building', 'landmark', 'construction', 'closed_road', 'sign', 'other');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- A submitted map point. `landmark` covers chowks/roundabouts. `construction`
-- and `closed_road` are transient alerts, not persistent places — see
-- `is_navigable` in routes/contributions.rs — so they never reach address
-- search even once approved.
CREATE TABLE IF NOT EXISTS place_contributions (
    id                  uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    contributor_id      uuid            NOT NULL,
    category            place_category  NOT NULL,
    name                text            NOT NULL,
    description         text,
    lat                 double precision NOT NULL,
    lng                 double precision NOT NULL,
    photo_storage_key   text            NOT NULL,
    -- Device GPS fix taken at the moment the photo was captured, and its
    -- distance from the claimed pin — the physical-presence proof.
    capture_lat         double precision NOT NULL,
    capture_lng         double precision NOT NULL,
    capture_distance_m  double precision NOT NULL,
    status              text            NOT NULL DEFAULT 'pending', -- pending | approved | rejected
    rejection_reason    text,
    reviewed_by         uuid,
    reviewed_at         timestamptz,
    points_awarded      integer,
    created_at          timestamptz     NOT NULL DEFAULT now(),
    updated_at          timestamptz     NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS place_contributions_status_idx
    ON place_contributions (status, created_at DESC);
CREATE INDEX IF NOT EXISTS place_contributions_contributor_idx
    ON place_contributions (contributor_id, created_at DESC);
CREATE INDEX IF NOT EXISTS place_contributions_approved_category_idx
    ON place_contributions (category) WHERE status = 'approved';

-- Append-only points ledger — balance = SUM(earned) - SUM(redeemed), same
-- shape as rides' credit_transactions.
CREATE TABLE IF NOT EXISTS points_ledger (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid        NOT NULL,
    contribution_id uuid        REFERENCES place_contributions(id),
    points          integer     NOT NULL,
    kind            text        NOT NULL, -- earned | redeemed
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS points_ledger_user_idx ON points_ledger (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS contributor_badges (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid        NOT NULL,
    badge_code text        NOT NULL,
    awarded_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, badge_code)
);
CREATE INDEX IF NOT EXISTS contributor_badges_user_idx ON contributor_badges (user_id);

-- Audit trail for points -> wallet-credit redemptions.
CREATE TABLE IF NOT EXISTS points_redemptions (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      uuid        NOT NULL,
    points_spent integer     NOT NULL,
    npr_amount   numeric     NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now()
);
