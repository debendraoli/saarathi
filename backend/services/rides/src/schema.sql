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
-- Cancellation: riders/drivers can cancel with a reason (feeds the complaints tab).
ALTER TABLE trips ADD COLUMN IF NOT EXISTS cancel_reason text;
ALTER TABLE trips ADD COLUMN IF NOT EXISTS cancelled_by uuid;
ALTER TABLE trips ADD COLUMN IF NOT EXISTS cancelled_by_role text;  -- rider | driver
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

-- Driver subscription passes ("unlimited for a period" — keep 100% of fares).
-- The fair-cap reconciliation refunds any driver who paid more than the 10% cap.
CREATE TABLE IF NOT EXISTS subscription_passes (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    driver_id      uuid        NOT NULL,
    plan           text        NOT NULL,
    price          numeric     NOT NULL,
    starts_at      timestamptz NOT NULL DEFAULT now(),
    ends_at        timestamptz NOT NULL,
    status         text        NOT NULL DEFAULT 'active',   -- active | expired | reconciled
    fair_cap_refund numeric    NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS subscription_passes_driver_idx ON subscription_passes (driver_id, ends_at DESC);

-- Fare bargaining record (algorithmic anchor + the bounded, legal agreed fare).
CREATE TABLE IF NOT EXISTS fare_negotiations (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_id      uuid        NOT NULL,
    algo_fare    numeric     NOT NULL,
    floor        numeric     NOT NULL,
    ceiling      numeric     NOT NULL,
    offered_fare numeric     NOT NULL,
    agreed_fare  numeric     NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS fare_negotiations_trip_idx ON fare_negotiations (trip_id);

-- Top-ups can fund a rider prepaid balance or a driver credit balance.
ALTER TABLE topup_intents ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'rider';

-- Credit top-up plans (min/max amount + optional bonus). Maker-checker:
-- staff create/edit (→ pending); admin/super-admin approve (→ active).
CREATE TABLE IF NOT EXISTS credit_plans (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    name          text        NOT NULL,
    min_amount    numeric     NOT NULL,
    max_amount    numeric     NOT NULL,
    bonus_percent numeric     NOT NULL DEFAULT 0,
    status        text        NOT NULL DEFAULT 'pending',  -- pending | active | rejected
    created_by    uuid,
    approved_by   uuid,
    review_note   text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    approved_at   timestamptz,
    updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS credit_plans_status_idx ON credit_plans (status);

-- ── Feature flags (dashboard-controlled circuit breakers) ──────────────────
-- Runtime kill-switches. The engine reads these on the hot paths (ride intake,
-- bargaining, surge, dispatch, delivery) so ops can shed load or freeze a
-- misbehaving subsystem from the dashboard without a deploy.
CREATE TABLE IF NOT EXISTS feature_flags (
    key         text        PRIMARY KEY,
    enabled     boolean     NOT NULL DEFAULT true,
    description text,
    updated_by  uuid,
    updated_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO feature_flags (key, enabled, description) VALUES
    ('rides.new_requests', true,  'Master switch for accepting new ride requests (circuit breaker).'),
    ('rides.bargaining',   true,  'Allow bounded fare bargaining on ride requests.'),
    ('pricing.surge',      true,  'Apply time-window and supply-based surge (clamped to the legal +20%).'),
    ('dispatch.enabled',   true,  'Run the automatic dispatch / matching engine.'),
    ('delivery.enabled',   false, 'Accept parcel / delivery jobs.')
ON CONFLICT (key) DO NOTHING;

-- ── Surge windows (dashboard-controlled time-of-day surcharge) ─────────────
-- Each active window that matches the current local time contributes a
-- multiplier; the engine takes the max and the legal clamp caps it at +20%.
CREATE TABLE IF NOT EXISTS surge_windows (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    label         text        NOT NULL,
    start_minute  int         NOT NULL,          -- minutes past local midnight [0,1440)
    end_minute    int         NOT NULL,          -- exclusive; may wrap past midnight
    multiplier    numeric     NOT NULL,          -- e.g. 1.15 (clamped to 1.20 by the engine)
    days_mask     int         NOT NULL DEFAULT 127,  -- bitmask, bit0=Sun … bit6=Sat
    vehicle_class text,                          -- null = any
    city          text,
    active        boolean     NOT NULL DEFAULT true,
    created_by    uuid,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS surge_windows_active_idx ON surge_windows (active);

-- ── Product analytics events (funnel / effectiveness tracking) ─────────────
-- Lightweight append-only event stream from the apps + server. Powers the
-- dashboard overview KPIs and future funnel analysis. Not money — kept separate
-- from the ledger.
CREATE TABLE IF NOT EXISTS analytics_events (
    id         bigserial   PRIMARY KEY,
    name       text        NOT NULL,             -- e.g. ride_requested, ride_completed, app_open
    user_id    uuid,
    role       text,                             -- rider | driver | staff | anon
    trip_id    uuid,
    props      jsonb       NOT NULL DEFAULT '{}',
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS analytics_events_name_idx ON analytics_events (name, created_at DESC);
CREATE INDEX IF NOT EXISTS analytics_events_user_idx ON analytics_events (user_id, created_at DESC);

-- ── Driver campaign payouts (driver-side incentives / quests) ──────────────
-- When a driver-audience campaign applies on trip completion, the bonus is
-- platform-funded and credited to the driver's earnings wallet; recorded here
-- (and in campaign_redemptions) for audit.
CREATE TABLE IF NOT EXISTS driver_bonus_grants (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id uuid        NOT NULL REFERENCES campaigns (id) ON DELETE CASCADE,
    driver_id   uuid        NOT NULL,
    trip_id     uuid,
    amount      numeric     NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS driver_bonus_grants_driver_idx ON driver_bonus_grants (driver_id, created_at DESC);
