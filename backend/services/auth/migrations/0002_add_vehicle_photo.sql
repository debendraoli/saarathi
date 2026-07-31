-- 0002_add_vehicle_photo.sql — the driver must also submit a photo of the
-- vehicle during KYC (plate + condition visible), alongside the profile photo.
-- ADD VALUE IF NOT EXISTS is idempotent and safe on PostgreSQL 12+.

ALTER TYPE document_kind ADD VALUE IF NOT EXISTS 'vehicle_photo';
