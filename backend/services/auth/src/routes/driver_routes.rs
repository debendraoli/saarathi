//! Driver registration + KYC document submission.

use crate::error::{AppError, AppResult};
use crate::models::{DocumentKind, Driver, DriverDocument, Vehicle, VehicleWheelerClass};
use crate::state::{AppState, AuthUser};
use axum::extract::{Multipart, Path, State};
use axum::http::header;
use axum::response::{IntoResponse, Response};
use axum::{
    routing::{get, post},
    Json, Router,
};
use chrono::NaiveDate;
use saarathi_core::api::ErrorCode;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/driver/register", post(register))
        .route("/v1/driver/documents", post(upload_document))
        .route("/v1/driver/status", get(status))
        .route("/v1/driver/kyc/submit", post(submit_kyc))
        .route("/v1/driver/{user_id}/photo", get(driver_photo))
}

/// Every document kind a driver must upload before their KYC can be reviewed —
/// mirrors the app's `DocKind.values` list.
const REQUIRED_DOC_KINDS: [&str; 7] = [
    "profile_photo",
    "citizenship_front",
    "citizenship_back",
    "license",
    "bluebook",
    "vehicle_photo",
    "insurance",
];

/// Gates KYC review on document completeness: a driver stays `pending` (kept
/// out of the staff queue) until they've uploaded every required document and
/// explicitly submit, at which point this flips them to `under_review`.
/// Re-submission after a rejection is allowed once the flagged issue is fixed.
async fn submit_kyc(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Driver>> {
    let driver_id: Uuid = sqlx::query_scalar("SELECT id FROM drivers WHERE user_id = $1")
        .bind(claims.sub)
        .fetch_optional(&st.db)
        .await?
        .ok_or_else(|| AppError::BadRequest("register as a driver first".into()))?;

    let uploaded: Vec<String> =
        sqlx::query_scalar("SELECT DISTINCT kind::text FROM driver_documents WHERE driver_id = $1")
            .bind(driver_id)
            .fetch_all(&st.db)
            .await?;
    let missing: Vec<&str> = REQUIRED_DOC_KINDS
        .into_iter()
        .filter(|k| !uploaded.iter().any(|u| u == k))
        .collect();
    if !missing.is_empty() {
        return Err(AppError::bad(
            ErrorCode::Validation,
            format!("missing required documents: {}", missing.join(", ")),
        ));
    }

    let driver: Driver = sqlx::query_as(
        "UPDATE drivers SET kyc_status = 'under_review', rejection_reason = NULL \
         WHERE id = $1 AND kyc_status IN ('pending', 'rejected') \
         RETURNING id, user_id, kyc_status, license_number, date_of_birth, address, \
                   rejection_reason, reviewed_by, reviewed_at, approved_at, service_types, created_at, updated_at",
    )
    .bind(driver_id)
    .fetch_optional(&st.db)
    .await?
    .ok_or_else(|| AppError::BadRequest("already submitted or reviewed".into()))?;

    Ok(Json(driver))
}

#[derive(Deserialize)]
struct VehicleInput {
    class: VehicleWheelerClass,
    make: Option<String>,
    model: Option<String>,
    year: Option<i32>,
    plate_number: String,
    color: Option<String>,
}

#[derive(Deserialize)]
struct RegisterInput {
    license_number: Option<String>,
    date_of_birth: Option<NaiveDate>,
    address: Option<String>,
    vehicle: VehicleInput,
    /// Job types this driver wants to accept — "ride", "delivery", or both.
    /// Defaults to ride-only when omitted (pre-existing behavior).
    service_types: Option<Vec<String>>,
}

/// Validates and normalizes a driver's requested service types, rejecting
/// anything outside `{"ride", "delivery"}` or an empty selection.
pub(crate) fn validate_service_types(input: Option<Vec<String>>) -> AppResult<Vec<String>> {
    let types = input.unwrap_or_else(|| vec!["ride".to_string()]);
    if types.is_empty() || types.iter().any(|t| t != "ride" && t != "delivery") {
        return Err(AppError::bad(
            ErrorCode::Validation,
            "service_types must be a non-empty subset of [\"ride\", \"delivery\"]",
        ));
    }
    Ok(types)
}

#[derive(Serialize)]
struct DriverProfile {
    driver: Driver,
    vehicle: Option<Vehicle>,
    documents: Vec<DriverDocument>,
}

async fn register(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<RegisterInput>,
) -> AppResult<Json<Driver>> {
    if body.license_number.as_deref().unwrap_or("").trim().is_empty() {
        return Err(AppError::BadRequest("license_number is required".into()));
    }
    if body.address.as_deref().unwrap_or("").trim().is_empty() {
        return Err(AppError::BadRequest("address is required".into()));
    }
    if body.vehicle.plate_number.trim().is_empty() {
        return Err(AppError::BadRequest("plate_number is required".into()));
    }
    if body.vehicle.model.as_deref().unwrap_or("").trim().is_empty() {
        return Err(AppError::BadRequest("vehicle model is required".into()));
    }
    let service_types = validate_service_types(body.service_types)?;
    let mut tx = st.db.begin().await?;

    // Promote the account to a driver (idempotent).
    sqlx::query("UPDATE users SET role = 'driver' WHERE id = $1 AND role = 'rider'")
        .bind(claims.sub)
        .execute(&mut *tx)
        .await?;

    let driver: Driver = sqlx::query_as(
        "INSERT INTO drivers (user_id, license_number, date_of_birth, address, kyc_status, service_types) \
         VALUES ($1, $2, $3, $4, 'pending', $5) \
         ON CONFLICT (user_id) DO UPDATE SET \
             license_number = EXCLUDED.license_number, \
             date_of_birth = EXCLUDED.date_of_birth, \
             address = EXCLUDED.address, \
             service_types = EXCLUDED.service_types \
         RETURNING id, user_id, kyc_status, license_number, date_of_birth, address, \
                   rejection_reason, reviewed_by, reviewed_at, approved_at, service_types, created_at, updated_at",
    )
    .bind(claims.sub)
    .bind(body.license_number)
    .bind(body.date_of_birth)
    .bind(body.address)
    .bind(&service_types)
    .fetch_one(&mut *tx)
    .await?;

    // One vehicle per driver for now: replace any existing.
    sqlx::query("DELETE FROM vehicles WHERE driver_id = $1")
        .bind(driver.id)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        "INSERT INTO vehicles (driver_id, class, make, model, year, plate_number, color) \
         VALUES ($1, $2, $3, $4, $5, $6, $7)",
    )
    .bind(driver.id)
    .bind(body.vehicle.class)
    .bind(body.vehicle.make)
    .bind(body.vehicle.model)
    .bind(body.vehicle.year)
    .bind(body.vehicle.plate_number)
    .bind(body.vehicle.color)
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(Json(driver))
}

async fn upload_document(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    mut multipart: Multipart,
) -> AppResult<Json<DriverDocument>> {
    let driver_id: Uuid = sqlx::query_scalar("SELECT id FROM drivers WHERE user_id = $1")
        .bind(claims.sub)
        .fetch_optional(&st.db)
        .await?
        .ok_or_else(|| AppError::BadRequest("register as a driver first".into()))?;

    let mut kind: Option<DocumentKind> = None;
    let mut content_type: Option<String> = None;
    let mut bytes: Option<Vec<u8>> = None;

    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| AppError::BadRequest(e.to_string()))?
    {
        match field.name() {
            Some("kind") => {
                let text = field
                    .text()
                    .await
                    .map_err(|e| AppError::BadRequest(e.to_string()))?;
                kind = Some(parse_kind(&text)?);
            }
            Some("file") => {
                content_type = field.content_type().map(|s| s.to_string());
                let data = field
                    .bytes()
                    .await
                    .map_err(|e| AppError::BadRequest(e.to_string()))?;
                bytes = Some(data.to_vec());
            }
            _ => {}
        }
    }

    let kind = kind.ok_or_else(|| AppError::BadRequest("missing 'kind' field".into()))?;
    let bytes = bytes.ok_or_else(|| AppError::BadRequest("missing 'file' field".into()))?;
    if bytes.is_empty() {
        return Err(AppError::BadRequest("empty file".into()));
    }

    let storage_key = format!("{driver_id}/{}", Uuid::new_v4());
    st.docs
        .put(&storage_key, bytes)
        .await
        .map_err(AppError::Other)?;

    let doc: DriverDocument = sqlx::query_as(
        "INSERT INTO driver_documents (driver_id, kind, storage_key, content_type, status) \
         VALUES ($1, $2, $3, $4, 'submitted') \
         RETURNING id, driver_id, kind, storage_key, content_type, status, expires_at, rejection_reason, created_at",
    )
    .bind(driver_id)
    .bind(kind)
    .bind(&storage_key)
    .bind(content_type)
    .fetch_one(&st.db)
    .await?;

    // First submission moves the driver into the review queue.
    sqlx::query(
        "UPDATE drivers SET kyc_status = 'under_review' WHERE id = $1 AND kyc_status = 'pending'",
    )
    .bind(driver_id)
    .execute(&st.db)
    .await?;

    Ok(Json(doc))
}

async fn status(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<DriverProfile>> {
    let driver: Driver = sqlx::query_as(
        "SELECT id, user_id, kyc_status, license_number, date_of_birth, address, \
                rejection_reason, reviewed_by, reviewed_at, approved_at, service_types, created_at, updated_at \
         FROM drivers WHERE user_id = $1",
    )
    .bind(claims.sub)
    .fetch_optional(&st.db)
    .await?
    .ok_or(AppError::NotFound)?;

    let vehicle: Option<Vehicle> = sqlx::query_as(
        "SELECT id, driver_id, class, make, model, year, plate_number, color FROM vehicles WHERE driver_id = $1",
    )
    .bind(driver.id)
    .fetch_optional(&st.db)
    .await?;

    let documents: Vec<DriverDocument> = sqlx::query_as(
        "SELECT id, driver_id, kind, storage_key, content_type, status, expires_at, rejection_reason, created_at \
         FROM driver_documents WHERE driver_id = $1 ORDER BY created_at",
    )
    .bind(driver.id)
    .fetch_all(&st.db)
    .await?;

    Ok(Json(DriverProfile {
        driver,
        vehicle,
        documents,
    }))
}

/// A driver's profile photo, for the counterpart card on the rider's side.
/// Gated like a phone number would be: the caller must either *be* the
/// driver or currently share a trip with them (any status — a finished
/// trip's driver photo isn't sensitive the way a phone number is, so unlike
/// `/v1/rides/{id}/participants` this doesn't narrow to active trips only).
async fn driver_photo(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(user_id): Path<Uuid>,
) -> AppResult<Response> {
    if claims.sub != user_id && !claims.is_staff() {
        let shares_trip: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM trips WHERE driver_id = $1 AND rider_id = $2)",
        )
        .bind(user_id)
        .bind(claims.sub)
        .fetch_one(&st.db)
        .await?;
        if !shares_trip {
            return Err(AppError::Forbidden);
        }
    }

    let row: Option<(String, Option<String>)> = sqlx::query_as(
        "SELECT dd.storage_key, dd.content_type FROM driver_documents dd \
         JOIN drivers d ON d.id = dd.driver_id \
         WHERE d.user_id = $1 AND dd.kind = 'profile_photo' \
         ORDER BY dd.created_at DESC LIMIT 1",
    )
    .bind(user_id)
    .fetch_optional(&st.db)
    .await?;
    let (storage_key, content_type) = row.ok_or(AppError::NotFound)?;

    let bytes = st
        .docs
        .get(&storage_key)
        .await
        .map_err(|_| AppError::NotFound)?;
    let ct = content_type.unwrap_or_else(|| "application/octet-stream".into());
    Ok(([(header::CONTENT_TYPE, ct)], bytes).into_response())
}

fn parse_kind(s: &str) -> Result<DocumentKind, AppError> {
    Ok(match s {
        "citizenship" => DocumentKind::Citizenship,
        "citizenship_front" => DocumentKind::CitizenshipFront,
        "citizenship_back" => DocumentKind::CitizenshipBack,
        "license" => DocumentKind::License,
        "bluebook" => DocumentKind::Bluebook,
        "vehicle_fitness" => DocumentKind::VehicleFitness,
        "insurance" => DocumentKind::Insurance,
        "tax_clearance" => DocumentKind::TaxClearance,
        "profile_photo" => DocumentKind::ProfilePhoto,
        "vehicle_photo" => DocumentKind::VehiclePhoto,
        other => {
            return Err(AppError::bad(
                ErrorCode::DocumentInvalid,
                format!("unknown document kind '{other}'"),
            ))
        }
    })
}
