-- Saarathi identity, KYC, and location schema. Applied idempotently at startup
-- via sqlx::raw_sql (no migration files — the DB is provisioned from this single
-- source of truth). Enforces the shape the compliance rules require: driver KYC
-- with manual staff verification, an audit trail, and PostGIS-backed location
-- data for riders and drivers. See ../../../../AGENTS.md for the golden rules.

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── Enums ──────────────────────────────────────────────────────────────────
DO $$ BEGIN
    CREATE TYPE user_role AS ENUM (
        'rider', 'driver',
        'super_admin', 'admin', 'dispatcher', 'finance', 'compliance', 'support', 'analyst'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE user_status AS ENUM ('pending', 'active', 'suspended', 'banned');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE kyc_status AS ENUM ('pending', 'under_review', 'approved', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE document_kind AS ENUM (
        'citizenship', 'license', 'bluebook', 'vehicle_fitness', 'insurance',
        'tax_clearance', 'profile_photo', 'vehicle_photo'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
-- Fold-in of the old 0002 migration (safe if the type predates 'vehicle_photo').
ALTER TYPE document_kind ADD VALUE IF NOT EXISTS 'vehicle_photo';
ALTER TYPE document_kind ADD VALUE IF NOT EXISTS 'citizenship_front';
ALTER TYPE document_kind ADD VALUE IF NOT EXISTS 'citizenship_back';

DO $$ BEGIN
    CREATE TYPE document_status AS ENUM ('submitted', 'approved', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE vehicle_class AS ENUM ('two_wheeler', 'four_wheeler');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Keep updated_at honest.
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ── Users ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    phone      text        NOT NULL UNIQUE,          -- E.164, e.g. +9779800000000
    full_name  text,
    role       user_role   NOT NULL DEFAULT 'rider',
    status     user_status NOT NULL DEFAULT 'active',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS users_updated_at ON users;
CREATE TRIGGER users_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── OTP codes ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS otp_codes (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    phone      text        NOT NULL,
    code_hash  text        NOT NULL,                 -- argon2 hash; never store the raw code
    purpose    text        NOT NULL DEFAULT 'login',
    attempts   int         NOT NULL DEFAULT 0,
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS otp_codes_phone_created_idx ON otp_codes (phone, created_at DESC);

-- ── Refresh tokens ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS refresh_tokens (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    token_hash text        NOT NULL UNIQUE,          -- sha256 of the random token
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS refresh_tokens_user_idx ON refresh_tokens (user_id);

-- ── Drivers (KYC) ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS drivers (
    id               uuid       PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id          uuid       NOT NULL UNIQUE REFERENCES users (id) ON DELETE CASCADE,
    kyc_status       kyc_status NOT NULL DEFAULT 'pending',
    license_number   text,
    date_of_birth    date,
    address          text,
    rejection_reason text,
    reviewed_by      uuid       REFERENCES users (id),  -- staff who decided
    reviewed_at      timestamptz,
    approved_at      timestamptz,
    -- On-site onboarding: which staff member captured this walk-in KYC (if any).
    onboarded_by     uuid       REFERENCES users (id),
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS drivers_updated_at ON drivers;
CREATE TRIGGER drivers_updated_at BEFORE UPDATE ON drivers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE INDEX IF NOT EXISTS drivers_kyc_status_idx ON drivers (kyc_status);
-- Safe on pre-existing databases that predate on-site onboarding.
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS onboarded_by uuid REFERENCES users (id);
-- Persisted availability toggle (mirrors the rides service's Redis presence so
-- the dashboard can show who is online and it survives a Redis flush).
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS is_online boolean NOT NULL DEFAULT false;
ALTER TABLE drivers ADD COLUMN IF NOT EXISTS last_online_at timestamptz;

-- ── Vehicles ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS vehicles (
    id           uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    driver_id    uuid          NOT NULL REFERENCES drivers (id) ON DELETE CASCADE,
    class        vehicle_class NOT NULL,
    make         text,
    model        text,
    year         int,
    plate_number text          NOT NULL,
    color        text,
    created_at   timestamptz   NOT NULL DEFAULT now(),
    updated_at   timestamptz   NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS vehicles_updated_at ON vehicles;
CREATE TRIGGER vehicles_updated_at BEFORE UPDATE ON vehicles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE INDEX IF NOT EXISTS vehicles_driver_idx ON vehicles (driver_id);

-- ── Driver documents ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS driver_documents (
    id               uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    driver_id        uuid            NOT NULL REFERENCES drivers (id) ON DELETE CASCADE,
    kind             document_kind   NOT NULL,
    storage_key      text            NOT NULL,       -- object-store key; bytes kept in-country
    content_type     text,
    status           document_status NOT NULL DEFAULT 'submitted',
    expires_at       date,
    rejection_reason text,
    created_at       timestamptz     NOT NULL DEFAULT now(),
    updated_at       timestamptz     NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS driver_documents_updated_at ON driver_documents;
CREATE TRIGGER driver_documents_updated_at BEFORE UPDATE ON driver_documents
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE INDEX IF NOT EXISTS driver_documents_driver_idx ON driver_documents (driver_id);

-- ── Saved locations (rider & driver favourites) ────────────────────────────
CREATE TABLE IF NOT EXISTS saved_locations (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    label      text        NOT NULL,                 -- home / work / custom
    address    text,
    lat        double precision NOT NULL,
    lng        double precision NOT NULL,
    geog       geography(Point, 4326)
               GENERATED ALWAYS AS (ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography) STORED,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS saved_locations_user_idx ON saved_locations (user_id);
CREATE INDEX IF NOT EXISTS saved_locations_geog_idx ON saved_locations USING GIST (geog);

-- ── Location pings (live / last-known position, riders and drivers) ─────────
CREATE TABLE IF NOT EXISTS location_pings (
    id          bigserial   PRIMARY KEY,
    user_id     uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    lat         double precision NOT NULL,
    lng         double precision NOT NULL,
    geog        geography(Point, 4326)
                GENERATED ALWAYS AS (ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography) STORED,
    accuracy_m  double precision,
    heading_deg double precision,
    speed_mps   double precision,
    recorded_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS location_pings_user_time_idx ON location_pings (user_id, recorded_at DESC);
CREATE INDEX IF NOT EXISTS location_pings_geog_idx ON location_pings USING GIST (geog);

-- ── Audit log (every privileged staff action) ──────────────────────────────
CREATE TABLE IF NOT EXISTS audit_log (
    id            bigserial   PRIMARY KEY,
    actor_user_id uuid        REFERENCES users (id),
    action        text        NOT NULL,
    entity_type   text,
    entity_id     uuid,
    detail        jsonb,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS audit_log_actor_idx  ON audit_log (actor_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS audit_log_entity_idx ON audit_log (entity_type, entity_id);

-- ── Per-user settings + synced recent searches (was migration 0003) ────────
CREATE TABLE IF NOT EXISTS user_preferences (
    user_id                uuid        PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    default_payment_method text        NOT NULL DEFAULT 'cash',    -- cash | wallet
    theme                  text        NOT NULL DEFAULT 'system',  -- system | light | dark
    updated_at             timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS recent_searches (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    label      text        NOT NULL,
    address    text,
    lat        double precision,
    lng        double precision,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS recent_searches_user_idx ON recent_searches (user_id, created_at DESC);

-- ── Fleet partnership program (doc 14) ─────────────────────────────────────
-- Multi-tenant fleet partners. A partner is an external org that brings + manages
-- supply; its staff have partner-scoped roles (separate from the platform RBAC).
DO $$ BEGIN
    CREATE TYPE partner_type AS ENUM ('fleet', 'corporate', 'agent');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE partner_status AS ENUM ('pending', 'active', 'suspended', 'terminated');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE partner_role AS ENUM
        ('owner', 'admin', 'manager', 'dispatcher', 'finance', 'support', 'viewer');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE partner_driver_status AS ENUM ('invited', 'active', 'suspended', 'left');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS partners (
    id               uuid           PRIMARY KEY DEFAULT gen_random_uuid(),
    name             text           NOT NULL,
    legal_name       text,
    type             partner_type   NOT NULL DEFAULT 'fleet',
    status           partner_status NOT NULL DEFAULT 'active',
    city             text,
    contact_phone    text,
    contact_email    text,
    pan_vat          text,
    -- Partner's slice of the platform's ≤10% commission (NOT of the driver's 90%).
    -- Clamped to the legal commission cap by the engine on write.
    commission_share numeric        NOT NULL DEFAULT 0,
    onboarded_by     uuid           REFERENCES users (id),
    created_at       timestamptz    NOT NULL DEFAULT now(),
    updated_at       timestamptz    NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS partners_updated_at ON partners;
CREATE TRIGGER partners_updated_at BEFORE UPDATE ON partners
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE INDEX IF NOT EXISTS partners_status_idx ON partners (status);

CREATE TABLE IF NOT EXISTS partner_members (
    id         uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    partner_id uuid         NOT NULL REFERENCES partners (id) ON DELETE CASCADE,
    user_id    uuid         NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    role       partner_role NOT NULL DEFAULT 'viewer',
    status     user_status  NOT NULL DEFAULT 'active',
    invited_by uuid         REFERENCES users (id),
    created_at timestamptz  NOT NULL DEFAULT now(),
    updated_at timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (partner_id, user_id)
);
DROP TRIGGER IF EXISTS partner_members_updated_at ON partner_members;
CREATE TRIGGER partner_members_updated_at BEFORE UPDATE ON partner_members
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE INDEX IF NOT EXISTS partner_members_user_idx ON partner_members (user_id);
CREATE INDEX IF NOT EXISTS partner_members_partner_idx ON partner_members (partner_id);

CREATE TABLE IF NOT EXISTS partner_drivers (
    id             uuid                  PRIMARY KEY DEFAULT gen_random_uuid(),
    partner_id     uuid                  NOT NULL REFERENCES partners (id) ON DELETE CASCADE,
    driver_user_id uuid                  NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    status         partner_driver_status NOT NULL DEFAULT 'active',
    revenue_share  numeric,              -- optional partner↔driver private split (off-platform record)
    invited_by     uuid                  REFERENCES users (id),
    joined_at      timestamptz           NOT NULL DEFAULT now(),
    left_at        timestamptz
);
-- A driver may be in at most one ACTIVE fleet at a time (anti-poaching invariant).
CREATE UNIQUE INDEX IF NOT EXISTS partner_drivers_one_active_idx
    ON partner_drivers (driver_user_id) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS partner_drivers_partner_idx ON partner_drivers (partner_id, status);

-- Corporate rider tabs: riders whose trips are billed to the partner's wallet
-- (ride-on-company-tab). Optional monthly spend cap per rider.
CREATE TABLE IF NOT EXISTS partner_riders (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    partner_id    uuid        NOT NULL REFERENCES partners (id) ON DELETE CASCADE,
    rider_user_id uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    status        text        NOT NULL DEFAULT 'active',   -- active | suspended | left
    monthly_cap   numeric,                                 -- null = unlimited
    invited_by    uuid        REFERENCES users (id),
    joined_at     timestamptz NOT NULL DEFAULT now(),
    left_at       timestamptz
);
-- A rider is on at most one active corporate tab at a time.
CREATE UNIQUE INDEX IF NOT EXISTS partner_riders_one_active_idx
    ON partner_riders (rider_user_id) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS partner_riders_partner_idx ON partner_riders (partner_id, status);

-- Partner dimension on the audit trail (partner-staff actions).
ALTER TABLE audit_log ADD COLUMN IF NOT EXISTS partner_id uuid;
