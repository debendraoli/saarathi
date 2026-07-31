//! Driver registration + KYC document submission.

use crate::error::{AppError, AppResult};
use crate::models::{Driver, DriverDocument, DocumentKind, Vehicle, VehicleClass};
use crate::state::{AppState, AuthUser};
use axum::extract::{Multipart, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use chrono::NaiveDate;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/driver/register", post(register))
        .route("/v1/driver/documents", post(upload_document))
        .route("/v1/driver/status", get(status))
}

#[derive(Deserialize)]
struct VehicleInput {
    class: VehicleClass,
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
    let mut tx = st.db.begin().await?;

    // Promote the account to a driver (idempotent).
    sqlx::query("UPDATE users SET role = 'driver' WHERE id = $1 AND role = 'rider'")
        .bind(claims.sub)
        .execute(&mut *tx)
        .await?;

    let driver: Driver = sqlx::query_as(
        "INSERT INTO drivers (user_id, license_number, date_of_birth, address, kyc_status) \
         VALUES ($1, $2, $3, $4, 'pending') \
         ON CONFLICT (user_id) DO UPDATE SET \
             license_number = EXCLUDED.license_number, \
             date_of_birth = EXCLUDED.date_of_birth, \
             address = EXCLUDED.address \
         RETURNING id, user_id, kyc_status, license_number, date_of_birth, address, \
                   rejection_reason, reviewed_by, reviewed_at, approved_at, created_at, updated_at",
    )
    .bind(claims.sub)
    .bind(body.license_number)
    .bind(body.date_of_birth)
    .bind(body.address)
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

    while let Some(field) = multipart.next_field().await.map_err(|e| AppError::BadRequest(e.to_string()))? {
        match field.name() {
            Some("kind") => {
                let text = field.text().await.map_err(|e| AppError::BadRequest(e.to_string()))?;
                kind = Some(parse_kind(&text)?);
            }
            Some("file") => {
                content_type = field.content_type().map(|s| s.to_string());
                let data = field.bytes().await.map_err(|e| AppError::BadRequest(e.to_string()))?;
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
    st.docs.put(&storage_key, bytes).await.map_err(AppError::Other)?;

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
    sqlx::query("UPDATE drivers SET kyc_status = 'under_review' WHERE id = $1 AND kyc_status = 'pending'")
        .bind(driver_id)
        .execute(&st.db)
        .await?;

    Ok(Json(doc))
}

async fn status(State(st): State<AppState>, AuthUser(claims): AuthUser) -> AppResult<Json<DriverProfile>> {
    let driver: Driver = sqlx::query_as(
        "SELECT id, user_id, kyc_status, license_number, date_of_birth, address, \
                rejection_reason, reviewed_by, reviewed_at, approved_at, created_at, updated_at \
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

    Ok(Json(DriverProfile { driver, vehicle, documents }))
}

fn parse_kind(s: &str) -> Result<DocumentKind, AppError> {
    Ok(match s {
        "citizenship" => DocumentKind::Citizenship,
        "license" => DocumentKind::License,
        "bluebook" => DocumentKind::Bluebook,
        "vehicle_fitness" => DocumentKind::VehicleFitness,
        "insurance" => DocumentKind::Insurance,
        "tax_clearance" => DocumentKind::TaxClearance,
        "profile_photo" => DocumentKind::ProfilePhoto,
        "vehicle_photo" => DocumentKind::VehiclePhoto,
        other => return Err(AppError::BadRequest(format!("unknown document kind '{other}'"))),
    })
}
