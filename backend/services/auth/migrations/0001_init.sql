-- 0001_init.sql — Saarathi identity, KYC, and location schema (Phase 0).
-- Enforces the shape the compliance rules require: driver KYC with manual
-- staff verification, an audit trail, and PostGIS-backed location data for
-- riders and drivers. See ../../../../AGENTS.md for the golden rules.

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── Enums ──────────────────────────────────────────────────────────────────
CREATE TYPE user_role AS ENUM (
    'rider', 'driver',
    'super_admin', 'admin', 'dispatcher', 'finance', 'compliance', 'support', 'analyst'
);
CREATE TYPE user_status     AS ENUM ('pending', 'active', 'suspended', 'banned');
CREATE TYPE kyc_status      AS ENUM ('pending', 'under_review', 'approved', 'rejected');
CREATE TYPE document_kind   AS ENUM (
    'citizenship', 'license', 'bluebook', 'vehicle_fitness', 'insurance', 'tax_clearance', 'profile_photo'
);
CREATE TYPE document_status AS ENUM ('submitted', 'approved', 'rejected');
CREATE TYPE vehicle_class   AS ENUM ('two_wheeler', 'four_wheeler');

-- Keep updated_at honest.
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ── Users ──────────────────────────────────────────────────────────────────
CREATE TABLE users (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    phone      text        NOT NULL UNIQUE,          -- E.164, e.g. +9779800000000
    full_name  text,
    role       user_role   NOT NULL DEFAULT 'rider',
    status     user_status NOT NULL DEFAULT 'active',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER users_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── OTP codes ──────────────────────────────────────────────────────────────
CREATE TABLE otp_codes (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    phone      text        NOT NULL,
    code_hash  text        NOT NULL,                 -- argon2 hash; never store the raw code
    purpose    text        NOT NULL DEFAULT 'login',
    attempts   int         NOT NULL DEFAULT 0,
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX otp_codes_phone_created_idx ON otp_codes (phone, created_at DESC);

-- ── Refresh tokens ─────────────────────────────────────────────────────────
CREATE TABLE refresh_tokens (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    uuid        NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    token_hash text        NOT NULL UNIQUE,          -- sha256 of the random token
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX refresh_tokens_user_idx ON refresh_tokens (user_id);

-- ── Drivers (KYC) ──────────────────────────────────────────────────────────
CREATE TABLE drivers (
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
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER drivers_updated_at BEFORE UPDATE ON drivers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE INDEX drivers_kyc_status_idx ON drivers (kyc_status);

-- ── Vehicles ───────────────────────────────────────────────────────────────
CREATE TABLE vehicles (
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
CREATE TRIGGER vehicles_updated_at BEFORE UPDATE ON vehicles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE INDEX vehicles_driver_idx ON vehicles (driver_id);

-- ── Driver documents ───────────────────────────────────────────────────────
CREATE TABLE driver_documents (
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
CREATE TRIGGER driver_documents_updated_at BEFORE UPDATE ON driver_documents
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE INDEX driver_documents_driver_idx ON driver_documents (driver_id);

-- ── Saved locations (rider & driver favourites) ────────────────────────────
CREATE TABLE saved_locations (
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
CREATE INDEX saved_locations_user_idx ON saved_locations (user_id);
CREATE INDEX saved_locations_geog_idx ON saved_locations USING GIST (geog);

-- ── Location pings (live / last-known position, riders and drivers) ─────────
CREATE TABLE location_pings (
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
CREATE INDEX location_pings_user_time_idx ON location_pings (user_id, recorded_at DESC);
CREATE INDEX location_pings_geog_idx ON location_pings USING GIST (geog);

-- ── Audit log (every privileged staff action) ──────────────────────────────
CREATE TABLE audit_log (
    id            bigserial   PRIMARY KEY,
    actor_user_id uuid        REFERENCES users (id),
    action        text        NOT NULL,
    entity_type   text,
    entity_id     uuid,
    detail        jsonb,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_log_actor_idx  ON audit_log (actor_user_id, created_at DESC);
CREATE INDEX audit_log_entity_idx ON audit_log (entity_type, entity_id);
