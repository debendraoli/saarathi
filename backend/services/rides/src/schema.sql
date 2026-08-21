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
    rules         jsonb             NOT NULL DEFAULT '[]',  -- dynamic eligibility rules (ANDed)
    created_by    uuid,
    created_at    timestamptz       NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS campaigns_active_idx ON campaigns (active);
-- Safe on pre-existing databases created before the rule engine.
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS rules jsonb NOT NULL DEFAULT '[]';

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

-- Parcel delivery (Phase 3a): a delivery is a trip with trip_type='delivery'
-- plus this extension. No merchant/catalog tables — parcel is point-to-point.
CREATE TABLE IF NOT EXISTS parcel_details (
    trip_id         uuid        PRIMARY KEY REFERENCES trips (id) ON DELETE CASCADE,
    size_tier       text        NOT NULL,                 -- envelope | small | medium
    recipient_name  text        NOT NULL,
    recipient_phone text        NOT NULL,
    declared_value  numeric     NOT NULL DEFAULT 0,
    fragile         boolean     NOT NULL DEFAULT false,
    cod_amount      numeric     NOT NULL DEFAULT 0,        -- cash collected from recipient, remitted to sender
    cod_remitted    boolean     NOT NULL DEFAULT false,
    pickup_note     text,
    delivery_otp    text        NOT NULL,                  -- recipient confirms this at hand-off
    pod_photo_key   text,                                  -- object-storage key of the proof photo
    pod_recipient   text,                                  -- who actually received it
    delivered_at    timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now()
);

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
-- Rider balances (kind='rider') may never go negative — enforced here as
-- defense-in-depth alongside debit_rider's application-level check (Phase 1
-- acceptance: a race can't push it negative). Driver balances (kind='driver')
-- are deliberately exempt: settle_driver_fee draws the platform's per-ride cut
-- from them and may dip negative if a driver's balance ran out between the
-- dispatch-time credit-floor check and trip completion — that's a short-lived
-- debt, not a bug, and the floor check keeps it the uncommon case.
CREATE TABLE IF NOT EXISTS credit_accounts (
    user_id    uuid        NOT NULL,
    kind       text        NOT NULL DEFAULT 'rider',
    balance    numeric     NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, kind)
);
-- Postgres has no ADD CONSTRAINT IF NOT EXISTS, so guard it explicitly for
-- databases where this table already existed pre-constraint.
DO $$ BEGIN
    ALTER TABLE credit_accounts ADD CONSTRAINT credit_accounts_rider_balance_nonneg
        CHECK (kind <> 'rider' OR balance >= 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

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
-- TDS withholding: the recipient nets `net_amount`; `tds_amount` is remitted.
ALTER TABLE payout_requests ADD COLUMN IF NOT EXISTS tds_amount numeric NOT NULL DEFAULT 0;
ALTER TABLE payout_requests ADD COLUMN IF NOT EXISTS net_amount numeric;
-- Weekly withdrawal fee (1 free per Nepal calendar week, 2% after) + which
-- saved payout account it was sent to.
ALTER TABLE payout_requests ADD COLUMN IF NOT EXISTS weekly_fee numeric NOT NULL DEFAULT 0;
ALTER TABLE payout_requests ADD COLUMN IF NOT EXISTS payout_account_id uuid;

-- Direct gateway payment for a specific trip's fare — e.g. a cash-designated
-- ride settled via Khalti instead of physical cash. The immutable
-- ledger_entries row from ride completion is never touched (append-only, per
-- AGENTS.md); on confirmation this credits the driver's wallet with the
-- trip's driver_payout share as its own credit_transaction, exactly as if it
-- had been a digital payment.
CREATE TABLE IF NOT EXISTS trip_gateway_payments (
    trip_id      uuid        PRIMARY KEY,
    reference    text        NOT NULL,
    provider     text        NOT NULL,
    amount       numeric     NOT NULL,
    status       text        NOT NULL DEFAULT 'pending',  -- pending | confirmed | failed
    created_at   timestamptz NOT NULL DEFAULT now(),
    confirmed_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS trip_gateway_payments_reference_idx ON trip_gateway_payments (reference);

-- Saved payout destinations (bank account or e-wallet). Exactly one default
-- per user is enforced at the DB level by the partial unique index below;
-- "at least one once any exist" is an application-level rule (see
-- routes::payout_accounts) since a partial unique index can't require presence.
CREATE TABLE IF NOT EXISTS payout_accounts (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid        NOT NULL,
    kind       text        NOT NULL,   -- bank | wallet
    label      text        NOT NULL,   -- display label, e.g. "NIC Asia ****1234"
    details    jsonb       NOT NULL,   -- bank_name/account_number/holder_name, or wallet provider/id
    is_default boolean     NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS payout_accounts_user_idx ON payout_accounts (user_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS payout_accounts_one_default_idx ON payout_accounts (user_id) WHERE is_default;

-- Idempotency keys for client-initiated money-moving requests (top-up,
-- withdrawal). Persisted (not in-memory) so a retry is safe across pod
-- restarts. `response` is filled in only once the mutation has committed
-- successfully, so a request that failed validation leaves no dangling
-- reservation and a retry with the same key just runs fresh.
CREATE TABLE IF NOT EXISTS idempotency_keys (
    key         text        NOT NULL,
    user_id     uuid        NOT NULL,
    endpoint    text        NOT NULL,
    status_code smallint,
    response    jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (key, user_id, endpoint)
);
CREATE INDEX IF NOT EXISTS idempotency_keys_created_idx ON idempotency_keys (created_at);

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
-- Payment disputes reuse this table+lifecycle (see saarathi-payments
-- routes::disputes) rather than a parallel schema; `reference` links the
-- report to a specific money-moving transaction (payout/topup reference,
-- or a credit_transaction id) instead of just a trip.
ALTER TABLE reports ADD COLUMN IF NOT EXISTS reference text;
CREATE INDEX IF NOT EXISTS reports_reference_idx ON reports (reference) WHERE reference IS NOT NULL;

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

-- DEPRECATED / frozen — the "unlimited for a period" subscription pass model
-- has been retired in favour of an always-on per-ride credit draw (no fee ever
-- exceeds the standard commission, so no fair-cap reconciliation is needed).
-- See docs/research/13-revenue-and-monetization.md and
-- `db::migrate_off_subscriptions`, which prorate-refunds any pass that was
-- still active at migration time into the driver's credit balance and flips
-- it to status = 'migrated'. Table is kept, unwritten, for historical audit —
-- no code reads or writes it outside that one-time migration.
CREATE TABLE IF NOT EXISTS subscription_passes (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    driver_id      uuid        NOT NULL,
    plan           text        NOT NULL,
    price          numeric     NOT NULL,
    starts_at      timestamptz NOT NULL DEFAULT now(),
    ends_at        timestamptz NOT NULL,
    status         text        NOT NULL DEFAULT 'active',   -- active | expired | reconciled | migrated
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

-- ── Fleet partner money (doc 14, Phase 2) ──────────────────────────────────
-- A partner earns a revenue-share carved from the platform's ≤10% commission
-- (never from the driver's ≥90%), and prepays a wallet to fund fleet promos.
-- Balance is +ve when the platform owes the partner (earnings/leftover top-up).
CREATE TABLE IF NOT EXISTS partner_wallets (
    partner_id uuid        PRIMARY KEY,
    balance    numeric     NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Append-only, hash-chained partner money movements (single global chain).
CREATE TABLE IF NOT EXISTS partner_ledger (
    seq         bigint      PRIMARY KEY,
    partner_id  uuid        NOT NULL,
    trip_id     uuid,
    kind        text        NOT NULL,   -- commission_share | promo_spend | topup | payout
    amount      numeric     NOT NULL,   -- signed: +owed to partner, -spent/withdrawn
    balance_after numeric   NOT NULL,
    prev_hash   text        NOT NULL,
    entry_hash  text        NOT NULL UNIQUE,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS partner_ledger_partner_idx ON partner_ledger (partner_id, created_at DESC);

CREATE TABLE IF NOT EXISTS partner_payouts (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    partner_id   uuid        NOT NULL,
    amount       numeric     NOT NULL,
    status       text        NOT NULL DEFAULT 'processing',   -- processing | paid | failed
    reference    text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    processed_at timestamptz
);
CREATE INDEX IF NOT EXISTS partner_payouts_partner_idx ON partner_payouts (partner_id, created_at DESC);
ALTER TABLE partner_payouts ADD COLUMN IF NOT EXISTS tds_amount numeric NOT NULL DEFAULT 0;
ALTER TABLE partner_payouts ADD COLUMN IF NOT EXISTS net_amount numeric;

-- Partner top-up intents share the PSP hand-off shape.
CREATE TABLE IF NOT EXISTS partner_topup_intents (
    reference    text        PRIMARY KEY,
    partner_id   uuid        NOT NULL,
    amount       numeric     NOT NULL,
    provider     text        NOT NULL,
    status       text        NOT NULL DEFAULT 'pending',  -- pending | confirmed | failed
    created_at   timestamptz NOT NULL DEFAULT now(),
    confirmed_at timestamptz
);

-- Fleet campaigns: a campaign may belong to a partner + be partner-funded.
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS partner_id uuid;
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS funded_by text NOT NULL DEFAULT 'platform';  -- platform | partner
CREATE INDEX IF NOT EXISTS campaigns_partner_idx ON campaigns (partner_id);

