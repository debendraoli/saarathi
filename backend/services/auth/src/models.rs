//! Domain enums (mapped to Postgres enum types) and row/DTO structs.

use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use uuid::Uuid;

// ── Enums ───────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "user_role", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum UserRole {
    Rider,
    Driver,
    SuperAdmin,
    Admin,
    Dispatcher,
    Finance,
    Compliance,
    Support,
    Analyst,
}

impl UserRole {
    /// Any non-rider, non-driver account is staff (dashboard user).
    pub fn is_staff(self) -> bool {
        !matches!(self, UserRole::Rider | UserRole::Driver)
    }

    /// Roles allowed to make KYC approve/reject decisions.
    pub fn can_review_kyc(self) -> bool {
        matches!(self, UserRole::SuperAdmin | UserRole::Admin | UserRole::Compliance)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "user_status", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum UserStatus {
    Pending,
    Active,
    Suspended,
    Banned,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "kyc_status", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum KycStatus {
    Pending,
    UnderReview,
    Approved,
    Rejected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "document_kind", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum DocumentKind {
    Citizenship,
    License,
    Bluebook,
    VehicleFitness,
    Insurance,
    TaxClearance,
    ProfilePhoto,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "document_status", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum DocumentStatus {
    Submitted,
    Approved,
    Rejected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "vehicle_class", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum VehicleClass {
    TwoWheeler,
    FourWheeler,
}

// ── Row structs ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct User {
    pub id: Uuid,
    pub phone: String,
    pub full_name: Option<String>,
    pub role: UserRole,
    pub status: UserStatus,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct Driver {
    pub id: Uuid,
    pub user_id: Uuid,
    pub kyc_status: KycStatus,
    pub license_number: Option<String>,
    pub date_of_birth: Option<NaiveDate>,
    pub address: Option<String>,
    pub rejection_reason: Option<String>,
    pub reviewed_by: Option<Uuid>,
    pub reviewed_at: Option<DateTime<Utc>>,
    pub approved_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct Vehicle {
    pub id: Uuid,
    pub driver_id: Uuid,
    pub class: VehicleClass,
    pub make: Option<String>,
    pub model: Option<String>,
    pub year: Option<i32>,
    pub plate_number: String,
    pub color: Option<String>,
}

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct DriverDocument {
    pub id: Uuid,
    pub driver_id: Uuid,
    pub kind: DocumentKind,
    pub storage_key: String,
    pub content_type: Option<String>,
    pub status: DocumentStatus,
    pub expires_at: Option<NaiveDate>,
    pub rejection_reason: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, FromRow)]
pub struct SavedLocation {
    pub id: Uuid,
    pub user_id: Uuid,
    pub label: String,
    pub address: Option<String>,
    pub lat: f64,
    pub lng: f64,
    pub created_at: DateTime<Utc>,
}
