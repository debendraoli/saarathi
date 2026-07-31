-- Rides schema. Applied idempotently at startup via sqlx::raw_sql so this
-- service can share the `saarathi` database with saarathi-auth without both
-- fighting over the single sqlx migrations table. Trips store plain lat/lng
-- (no PostGIS needed here); distance for fares comes from the routing client.

DO $$ BEGIN
    CREATE TYPE trip_type AS ENUM ('ride', 'delivery');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE trip_status AS ENUM ('requested', 'accepted', 'arriving', 'in_progress', 'completed', 'cancelled');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE campaign_audience AS ENUM ('rider', 'driver');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE discount_kind AS ENUM ('percent', 'flat');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS trips (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    rider_id        uuid        NOT NULL,
    driver_id       uuid,
    trip_type       trip_type   NOT NULL DEFAULT 'ride',
    status          trip_status NOT NULL DEFAULT 'requested',
    vehicle_class   text        NOT NULL,             -- 'two_wheeler' | 'four_wheeler'
    origin_lat      double precision NOT NULL,
    origin_lng      double precision NOT NULL,
    dest_lat        double precision NOT NULL,
    dest_lng        double precision NOT NULL,
    distance_km     numeric     NOT NULL,
    duration_secs   int         NOT NULL,
    gross_fare      numeric     NOT NULL,             -- fare before promo (drives the ledger split)
    discount_code   text,
    discount_amount numeric     NOT NULL DEFAULT 0,
    final_fare      numeric     NOT NULL,             -- what the rider is charged
    commission      numeric     NOT NULL,
    accident_fund   numeric     NOT NULL,
    driver_payout   numeric     NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    accepted_at     timestamptz,
    completed_at    timestamptz,
    cancelled_at    timestamptz,
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS trips_rider_idx  ON trips (rider_id, created_at DESC);
CREATE INDEX IF NOT EXISTS trips_driver_idx ON trips (driver_id, created_at DESC);
CREATE INDEX IF NOT EXISTS trips_status_idx ON trips (status);

CREATE TABLE IF NOT EXISTS campaigns (
    id            uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
    code          text              NOT NULL UNIQUE,
    title         text              NOT NULL,
    audience      campaign_audience NOT NULL DEFAULT 'rider',
    kind          discount_kind     NOT NULL,
    value         numeric           NOT NULL,         -- percent (0-100) or flat NPR
    min_fare      numeric           NOT NULL DEFAULT 0,
    max_discount  numeric,                            -- cap for percent promos
    city          text,
    vehicle_class text,                               -- null = any
    starts_at     timestamptz,
    ends_at       timestamptz,
    active        boolean           NOT NULL DEFAULT true,
    usage_limit   int,                                -- null = unlimited
    used_count    int               NOT NULL DEFAULT 0,
    created_by    uuid,
    created_at    timestamptz       NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS campaigns_active_idx ON campaigns (active);

CREATE TABLE IF NOT EXISTS campaign_redemptions (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id uuid        NOT NULL REFERENCES campaigns (id) ON DELETE CASCADE,
    user_id     uuid        NOT NULL,
    trip_id     uuid,
    amount      numeric     NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS campaign_redemptions_campaign_idx ON campaign_redemptions (campaign_id);

-- Near-realtime event log (location pings, status changes, chat, WebRTC signals).
CREATE TABLE IF NOT EXISTS trip_events (
    id         bigserial   PRIMARY KEY,
    trip_id    uuid        NOT NULL,
    sender_id  uuid,
    kind       text        NOT NULL,                  -- location | status | chat | signal
    payload    jsonb       NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS trip_events_trip_idx ON trip_events (trip_id, created_at DESC);

-- Payment method on the trip (drives the ledger + wallet settlement).
ALTER TABLE trips ADD COLUMN IF NOT EXISTS payment_method text NOT NULL DEFAULT 'cash';
-- Multi-stop waypoints: [{ "lat":.., "lng":.. }, …] between origin and destination.
ALTER TABLE trips ADD COLUMN IF NOT EXISTS stops jsonb NOT NULL DEFAULT '[]';

-- Immutable, hash-chained ledger. One entry per completed trip (unique index).
CREATE TABLE IF NOT EXISTS ledger_entries (
    seq            bigint      PRIMARY KEY,
    trip_id        uuid        NOT NULL,
    driver_id      uuid,
    gross          numeric     NOT NULL,
    commission     numeric     NOT NULL,
    accident_fund  numeric     NOT NULL,
    driver_payout  numeric     NOT NULL,
    payment_method text        NOT NULL,
    prev_hash      text        NOT NULL,
    entry_hash     text        NOT NULL UNIQUE,
    report_status  text        NOT NULL DEFAULT 'pending',  -- DoTM report state (E4)
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS ledger_entries_trip_idx ON ledger_entries (trip_id);

-- Driver balance wallet: +ve = platform owes driver; -ve = driver owes platform.
CREATE TABLE IF NOT EXISTS driver_wallets (
    driver_id  uuid        PRIMARY KEY,
    balance    numeric     NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Dispatch offers: one row per (trip, driver) offer in the sequential-offer flow.
CREATE TABLE IF NOT EXISTS trip_offers (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_id    uuid        NOT NULL,
    driver_id  uuid        NOT NULL,
    status     text        NOT NULL DEFAULT 'offered',  -- offered | accepted | declined | expired
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS trip_offers_trip_idx   ON trip_offers (trip_id);
CREATE INDEX IF NOT EXISTS trip_offers_driver_idx ON trip_offers (driver_id, status);
CREATE INDEX IF NOT EXISTS trip_offers_active_idx ON trip_offers (status, expires_at);

-- Rider/customer prepaid credit balance (customer pays the platform directly).
CREATE TABLE IF NOT EXISTS credit_accounts (
    user_id    uuid        NOT NULL,
    kind       text        NOT NULL DEFAULT 'rider',
    balance    numeric     NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, kind)
);

-- Append-only money movements: top-ups, ride payments, payouts, bonuses, refunds.
CREATE TABLE IF NOT EXISTS credit_transactions (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       uuid        NOT NULL,
    kind          text        NOT NULL,               -- rider | driver
    txn_type      text        NOT NULL,               -- topup | payment | payout | bonus | refund
    amount        numeric     NOT NULL,               -- signed: +credit, -debit
    balance_after numeric,
    reference     text,
    trip_id       uuid,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS credit_transactions_user_idx ON credit_transactions (user_id, created_at DESC);

-- Top-up intents (the PSP hand-off; confirmed by a webhook/callback).
CREATE TABLE IF NOT EXISTS topup_intents (
    reference    text        PRIMARY KEY,
    user_id      uuid        NOT NULL,
    amount       numeric     NOT NULL,
    provider     text        NOT NULL,
    status       text        NOT NULL DEFAULT 'pending',  -- pending | confirmed | failed
    created_at   timestamptz NOT NULL DEFAULT now(),
    confirmed_at timestamptz
);

-- Driver withdrawals of their earnings balance.
CREATE TABLE IF NOT EXISTS payout_requests (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    driver_id    uuid        NOT NULL,
    amount       numeric     NOT NULL,
    status       text        NOT NULL DEFAULT 'processing',  -- processing | paid | failed
    reference    text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    processed_at timestamptz
);
CREATE INDEX IF NOT EXISTS payout_requests_driver_idx ON payout_requests (driver_id, created_at DESC);

-- Two-sided ratings (rider↔driver), tag-based (one per rater per trip).
CREATE TABLE IF NOT EXISTS ratings (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_id    uuid        NOT NULL,
    rater_id   uuid        NOT NULL,
    ratee_id   uuid        NOT NULL,
    role       text        NOT NULL,   -- rider_rates_driver | driver_rates_rider
    stars      int         NOT NULL,
    tags       text[]      NOT NULL DEFAULT '{}',
    comment    text,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS ratings_trip_rater_idx ON ratings (trip_id, rater_id);
CREATE INDEX IF NOT EXISTS ratings_ratee_idx ON ratings (ratee_id);

-- Reports / grievances (safety, payment, behaviour, delivery, lost item…).
CREATE TABLE IF NOT EXISTS reports (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    reporter_id uuid        NOT NULL,
    subject_id  uuid,
    trip_id     uuid,
    category    text        NOT NULL,
    severity    text        NOT NULL DEFAULT 'normal',
    detail      text,
    status      text        NOT NULL DEFAULT 'open',  -- open | investigating | resolved | dismissed
    resolution  text,
    handled_by  uuid,
    created_at  timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz
);
CREATE INDEX IF NOT EXISTS reports_status_idx ON reports (status, created_at DESC);

-- SOS / emergency incidents (rider or driver), audit-grade.
CREATE TABLE IF NOT EXISTS sos_incidents (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid        NOT NULL,
    trip_id     uuid,
    lat         double precision,
    lng         double precision,
    channel     text        NOT NULL DEFAULT 'app',   -- app | sms
    status      text        NOT NULL DEFAULT 'active',  -- active | resolved
    note        text,
    resolved_by uuid,
    created_at  timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz
);
CREATE INDEX IF NOT EXISTS sos_status_idx ON sos_incidents (status, created_at DESC);

-- In-app notification inbox (the durable record; push/SMS are best-effort on top).
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
