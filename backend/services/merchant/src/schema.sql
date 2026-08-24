-- saarathi-merchant schema — owns the merchant/menu/order tables, extracted
-- from saarathi-rides (Phase 2: merchant domain decoupling). Applied
-- idempotently at startup via sqlx::raw_sql, same convention as auth/rides.
-- Shares the Postgres instance with the other services (per AGENTS.md:
-- "per-service schemas, shared instance early"); orders.customer_id
-- references auth's users(id), the same cross-service pattern payments/
-- partners already use against rides-owned tables.

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── Marketplace (food / grocery) ────────────────────────────────────────────
-- Merchants, their menu, and customer orders. When an order is marked 'ready'
-- it spawns a delivery trip (trip_type='delivery') so the courier leg reuses the
-- existing dispatch + settlement machinery.
CREATE TABLE IF NOT EXISTS merchants (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_user_id uuid,                                   -- merchant app account (nullable in v0)
    name          text        NOT NULL,
    vertical      text        NOT NULL,                   -- food | grocery
    address       text,
    phone         text,
    lat           double precision NOT NULL,
    lng           double precision NOT NULL,
    geog          geography(Point, 4326)
                  GENERATED ALWAYS AS (ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography) STORED,
    prep_mins     int         NOT NULL DEFAULT 20,
    is_open       boolean     NOT NULL DEFAULT true,
    rating        numeric     NOT NULL DEFAULT 0,
    image_key     text,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS merchants_vertical_idx ON merchants (vertical);
CREATE INDEX IF NOT EXISTS merchants_geog_idx ON merchants USING GIST (geog);
-- Tax id captured at self-onboarding (PAN / VAT).
ALTER TABLE merchants ADD COLUMN IF NOT EXISTS pan_vat text;
-- Delivery/visibility geofence: a polygon boundary as [{lat,lng}, ...]
-- (closed or open ring, either is accepted). Null = no zone defined yet.
-- The H3 resolution-9 cell coverage is derived from this and cached in Redis
-- (see routes::zone) — recomputed synchronously on every write here,
-- which is the invalidation strategy: the cache can never be stale because
-- nothing else can change `zone_polygon` out from under it.
ALTER TABLE merchants ADD COLUMN IF NOT EXISTS zone_polygon jsonb;
-- Raw storage key for an uploaded shop photo (opaque, resolved via
-- DocumentStore) — distinct from `image_key`, which is the client-facing
-- src (a URL or a relative API path) and may point at a seeded demo photo
-- instead. Null until the owner uploads one.
ALTER TABLE merchants ADD COLUMN IF NOT EXISTS photo_storage_key text;

-- Staff approval gate, mirroring drivers.kyc_status in auth's schema (minus
-- the document-completeness 'under_review' step — a merchant application has
-- nothing to upload, so staff review directly off 'pending'). A merchant
-- can't open for business (`is_open=true`) or appear in public discovery
-- until 'approved'.
DO $$ BEGIN
    CREATE TYPE merchant_status AS ENUM ('pending', 'approved', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE merchants ADD COLUMN IF NOT EXISTS status merchant_status NOT NULL DEFAULT 'pending';
ALTER TABLE merchants ADD COLUMN IF NOT EXISTS rejection_reason text;
ALTER TABLE merchants ADD COLUMN IF NOT EXISTS reviewed_by uuid;
ALTER TABLE merchants ADD COLUMN IF NOT EXISTS reviewed_at timestamptz;
ALTER TABLE merchants ADD COLUMN IF NOT EXISTS approved_at timestamptz;
CREATE INDEX IF NOT EXISTS merchants_status_idx ON merchants (status);

-- One store per registration: a rejected application doesn't hold the slot
-- (the owner can re-apply), but a pending or approved one does. Backstops
-- the application-level check in apply_merchant/create_merchant.
CREATE UNIQUE INDEX IF NOT EXISTS merchants_one_active_per_owner_idx
    ON merchants (owner_user_id) WHERE status <> 'rejected' AND owner_user_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS menu_items (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    merchant_id  uuid        NOT NULL REFERENCES merchants (id) ON DELETE CASCADE,
    name         text        NOT NULL,
    description  text,
    category     text,
    price        numeric     NOT NULL,
    is_available boolean     NOT NULL DEFAULT true,
    image_key    text,
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS menu_items_merchant_idx ON menu_items (merchant_id);
ALTER TABLE menu_items ADD COLUMN IF NOT EXISTS photo_storage_key text;

CREATE TABLE IF NOT EXISTS orders (
    id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    merchant_id    uuid        NOT NULL REFERENCES merchants (id),
    status         text        NOT NULL DEFAULT 'placed',  -- placed|confirmed|preparing|ready|picked_up|delivered|cancelled|rejected
    subtotal       numeric     NOT NULL,
    delivery_fee   numeric     NOT NULL DEFAULT 0,
    total          numeric     NOT NULL,
    payment_method text        NOT NULL DEFAULT 'cash',    -- cash | wallet
    delivery_lat   double precision NOT NULL,
    delivery_lng   double precision NOT NULL,
    delivery_note  text,
    trip_id        uuid,                                   -- courier delivery trip once dispatched
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS orders_customer_idx ON orders (customer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS orders_merchant_idx ON orders (merchant_id, status);

-- Store-owned promotions: free delivery or a %/flat discount over a
-- minimum order amount, optionally boxed to a date range and/or a daily
-- time-of-day window ("between 5pm and 8pm"). Self-service — configured by
-- the merchant owner, not staff; no rider/driver "audience" or rule engine
-- like rides' `campaigns` table, just a threshold and an optional window.
CREATE TABLE IF NOT EXISTS merchant_offers (
    id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    merchant_id        uuid        NOT NULL REFERENCES merchants (id) ON DELETE CASCADE,
    kind               text        NOT NULL,   -- 'free_delivery' | 'percent' | 'flat'
    value              numeric,                -- % or flat NPR; unused for free_delivery
    max_discount       numeric,                -- cap, percent only
    min_order_amount   numeric     NOT NULL DEFAULT 0,
    starts_at          timestamptz,            -- date-range window (e.g. "this week/month")
    ends_at            timestamptz,
    daily_start_minute int,                    -- optional "between time X and Y" window,
    daily_end_minute   int,                    -- both null = all day, both set = daily window
    active             boolean     NOT NULL DEFAULT true,
    created_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS merchant_offers_merchant_idx ON merchant_offers (merchant_id, active);

ALTER TABLE orders ADD COLUMN IF NOT EXISTS discount_amount numeric NOT NULL DEFAULT 0;
ALTER TABLE orders ADD COLUMN IF NOT EXISTS offer_id uuid REFERENCES merchant_offers (id);

CREATE TABLE IF NOT EXISTS order_items (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id     uuid        NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
    menu_item_id uuid        NOT NULL,
    name         text        NOT NULL,
    unit_price   numeric     NOT NULL,
    qty          int         NOT NULL
);
CREATE INDEX IF NOT EXISTS order_items_order_idx ON order_items (order_id);

-- Customer ratings of the merchant itself (separate from rides' `ratings`,
-- which is trip-centric — an order isn't always tied to a courier trip, but
-- should always be ratable once delivered).
CREATE TABLE IF NOT EXISTS merchant_ratings (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id    uuid        NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
    merchant_id uuid        NOT NULL REFERENCES merchants (id),
    rater_id    uuid        NOT NULL,
    stars       int         NOT NULL,
    tags        text[]      NOT NULL DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS merchant_ratings_order_rater_idx ON merchant_ratings (order_id, rater_id);
CREATE INDEX IF NOT EXISTS merchant_ratings_merchant_idx ON merchant_ratings (merchant_id);

-- Keeps `merchants.rating` fresh on every new/updated rating so listing
-- queries (a hot path) stay a plain column read instead of an aggregate.
CREATE OR REPLACE FUNCTION recompute_merchant_rating() RETURNS trigger AS $$
BEGIN
    UPDATE merchants SET rating = COALESCE(
        (SELECT avg(stars) FROM merchant_ratings WHERE merchant_id = NEW.merchant_id), 0)
    WHERE id = NEW.merchant_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS merchant_ratings_recompute ON merchant_ratings;
CREATE TRIGGER merchant_ratings_recompute
AFTER INSERT OR UPDATE ON merchant_ratings
FOR EACH ROW EXECUTE FUNCTION recompute_merchant_rating();

-- Dev seed: two demo merchants in Ghorahi so the app has something to browse.
INSERT INTO merchants (id, name, vertical, address, phone, lat, lng, prep_mins, rating) VALUES
    ('11111111-1111-1111-1111-111111111111', 'Ghorahi Momo House', 'food', 'Traffic Chowk, Ghorahi', '+9779800000101', 28.0339, 82.4855, 18, 4.6),
    ('22222222-2222-2222-2222-222222222222', 'Tulsipur Fresh Mart', 'grocery', 'Bus Park, Tulsipur', '+9779800000102', 28.1300, 82.2970, 25, 4.4)
ON CONFLICT (id) DO NOTHING;

INSERT INTO menu_items (id, merchant_id, name, description, category, price) VALUES
    ('a1111111-1111-1111-1111-111111111101', '11111111-1111-1111-1111-111111111111', 'Buff Momo (10 pcs)', 'Steamed, with achar', 'Momo', 160),
    ('a1111111-1111-1111-1111-111111111102', '11111111-1111-1111-1111-111111111111', 'Veg Chowmein', 'Stir-fried noodles', 'Noodles', 130),
    ('a1111111-1111-1111-1111-111111111103', '11111111-1111-1111-1111-111111111111', 'Chicken Sekuwa', 'Grilled, 250g', 'Grill', 250),
    ('a2222222-2222-2222-2222-222222222201', '22222222-2222-2222-2222-222222222222', 'Rice 5kg', 'Sona Mansuli', 'Staples', 480),
    ('a2222222-2222-2222-2222-222222222202', '22222222-2222-2222-2222-222222222222', 'Cooking Oil 1L', 'Sunflower', 'Staples', 250),
    ('a2222222-2222-2222-2222-222222222203', '22222222-2222-2222-2222-222222222222', 'Eggs (30)', 'Farm fresh tray', 'Dairy', 480)
ON CONFLICT (id) DO NOTHING;

-- Demo photos for the seed menu (idempotent; real merchants upload their own).
UPDATE menu_items SET image_key = CASE id
    WHEN 'a1111111-1111-1111-1111-111111111101' THEN 'https://images.unsplash.com/photo-1534422298391-e4f8c172dddb?w=400&q=60&auto=format&fit=crop'
    WHEN 'a1111111-1111-1111-1111-111111111102' THEN 'https://images.unsplash.com/photo-1585032226651-759b368d7246?w=400&q=60&auto=format&fit=crop'
    WHEN 'a1111111-1111-1111-1111-111111111103' THEN 'https://images.unsplash.com/photo-1555939594-58d7cb561ad1?w=400&q=60&auto=format&fit=crop'
    WHEN 'a2222222-2222-2222-2222-222222222201' THEN 'https://images.unsplash.com/photo-1586201375761-83865001e31c?w=400&q=60&auto=format&fit=crop'
    WHEN 'a2222222-2222-2222-2222-222222222202' THEN 'https://images.unsplash.com/photo-1474979266404-7eaacbcd87c5?w=400&q=60&auto=format&fit=crop'
    WHEN 'a2222222-2222-2222-2222-222222222203' THEN 'https://images.unsplash.com/photo-1518569656558-1f25e69d93d7?w=400&q=60&auto=format&fit=crop'
    ELSE image_key
END
WHERE id IN (
    'a1111111-1111-1111-1111-111111111101',
    'a1111111-1111-1111-1111-111111111102',
    'a1111111-1111-1111-1111-111111111103',
    'a2222222-2222-2222-2222-222222222201',
    'a2222222-2222-2222-2222-222222222202',
    'a2222222-2222-2222-2222-222222222203'
);
