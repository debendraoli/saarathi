//! Driver verification queue, KYC approval/rejection, suspend/reactivate,
//! and on-site (walk-in) onboarding.

use crate::audit;
use crate::error::{AppError, AppResult};
use crate::models::{Driver, DriverDocument, User, Vehicle, VehicleWheelerClass};
use crate::state::{AdminUser, AppState, StaffUser};
use axum::extract::{Path, Query, State};
use axum::Json;
use chrono::NaiveDate;
use saarathi_core::api::ErrorCode;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

#[derive(Deserialize)]
pub(super) struct ListQuery {
    status: Option<String>,
}

#[derive(Serialize, sqlx::FromRow)]
pub(super) struct DriverListItem {
    id: Uuid,
    user_id: Uuid,
    kyc_status: crate::models::KycStatus,
    full_name: Option<String>,
    phone: String,
    license_number: Option<String>,
    service_types: Vec<String>,
    created_at: chrono::DateTime<chrono::Utc>,
    reviewed_at: Option<chrono::DateTime<chrono::Utc>>,
}

pub(super) async fn list_drivers(
    State(st): State<AppState>,
    _staff: StaffUser,
    Query(q): Query<ListQuery>,
) -> AppResult<Json<Vec<DriverListItem>>> {
    // Default to the actionable queue — `pending` means the driver hasn't
    // finished uploading documents and submitted yet (see POST
    // /v1/driver/kyc/submit), so it's deliberately excluded here.
    let status_filter = q.status.unwrap_or_else(|| "queue".into());

    let base = "SELECT d.id, d.user_id, d.kyc_status, u.full_name, u.phone, \
                d.license_number, d.service_types, d.created_at, d.reviewed_at \
                FROM drivers d JOIN users u ON u.id = d.user_id ";

    let items: Vec<DriverListItem> = if status_filter == "queue" {
        sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "{base} WHERE d.kyc_status = 'under_review' ORDER BY d.created_at",
        )))
        .fetch_all(&st.db)
        .await?
    } else {
        sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "{base} WHERE d.kyc_status::text = $1 ORDER BY d.created_at DESC"
        )))
        .bind(&status_filter)
        .fetch_all(&st.db)
        .await?
    };

    Ok(Json(items))
}

#[derive(Serialize)]
pub(super) struct DriverDetail {
    driver: Driver,
    user: User,
    vehicle: Option<Vehicle>,
    documents: Vec<DriverDocument>,
}

pub(super) async fn driver_detail(
    State(st): State<AppState>,
    _staff: StaffUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<DriverDetail>> {
    let driver: Driver = sqlx::query_as(
        "SELECT id, user_id, kyc_status, license_number, date_of_birth, address, \
                rejection_reason, reviewed_by, reviewed_at, approved_at, service_types, created_at, updated_at \
         FROM drivers WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(&st.db)
    .await?
    .ok_or(AppError::NotFound)?;

    let user: User = sqlx::query_as(
        "SELECT id, phone, full_name, role, status, created_at, updated_at FROM users WHERE id = $1",
    )
    .bind(driver.user_id)
    .fetch_one(&st.db)
    .await?;

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

    Ok(Json(DriverDetail {
        driver,
        user,
        vehicle,
        documents,
    }))
}

pub(super) async fn approve_driver(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    if !claims.can_review_kyc() {
        return Err(AppError::Forbidden);
    }
    let mut tx = st.db.begin().await?;

    // Guarded on the current status (not just existence) so two staff acting
    // on the same driver at once can't silently clobber each other — the
    // loser's WHERE clause simply matches nothing.
    let updated = sqlx::query(
        "UPDATE drivers SET kyc_status = 'approved', approved_at = now(), reviewed_at = now(), \
         reviewed_by = $2, rejection_reason = NULL \
         WHERE id = $1 AND kyc_status = 'under_review'",
    )
    .bind(id)
    .bind(claims.sub)
    .execute(&mut *tx)
    .await?;
    if updated.rows_affected() == 0 {
        let exists: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM drivers WHERE id = $1)")
            .bind(id)
            .fetch_one(&mut *tx)
            .await?;
        return Err(if exists {
            AppError::conflict(
                ErrorCode::Conflict,
                "driver has already been reviewed (or hasn't submitted for review yet)",
            )
        } else {
            AppError::NotFound
        });
    }

    // Activate the underlying user account.
    let user_id: Uuid = sqlx::query_scalar(
        "UPDATE users SET status = 'active' \
         WHERE id = (SELECT user_id FROM drivers WHERE id = $1) RETURNING id",
    )
    .bind(id)
    .fetch_one(&mut *tx)
    .await?;

    audit::record(
        &st.db,
        claims.sub,
        "driver.approve",
        "driver",
        id,
        json!({}),
    )
    .await?;
    tx.commit().await?;

    crate::notify::send(
        &st.nats,
        user_id,
        saarathi_core::domain::notif::TRANSACTIONAL,
        "You're verified!",
        "Your driver KYC was approved — you can start accepting rides now.",
        None,
    )
    .await;

    Ok(Json(json!({ "ok": true, "kyc_status": "approved" })))
}

#[derive(Deserialize)]
pub(super) struct RejectInput {
    reason: String,
}

pub(super) async fn reject_driver(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Path(id): Path<Uuid>,
    Json(body): Json<RejectInput>,
) -> AppResult<Json<Value>> {
    if !claims.can_review_kyc() {
        return Err(AppError::Forbidden);
    }
    if body.reason.trim().is_empty() {
        return Err(AppError::BadRequest(
            "a rejection reason is required".into(),
        ));
    }

    let updated: Option<(Uuid,)> = sqlx::query_as(
        "UPDATE drivers SET kyc_status = 'rejected', reviewed_at = now(), reviewed_by = $2, \
         rejection_reason = $3, approved_at = NULL \
         WHERE id = $1 AND kyc_status = 'under_review' RETURNING user_id",
    )
    .bind(id)
    .bind(claims.sub)
    .bind(&body.reason)
    .fetch_optional(&st.db)
    .await?;
    let Some((user_id,)) = updated else {
        let exists: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM drivers WHERE id = $1)")
            .bind(id)
            .fetch_one(&st.db)
            .await?;
        return Err(if exists {
            AppError::conflict(
                ErrorCode::Conflict,
                "driver has already been reviewed (or hasn't submitted for review yet)",
            )
        } else {
            AppError::NotFound
        });
    };

    audit::record(
        &st.db,
        claims.sub,
        "driver.reject",
        "driver",
        id,
        json!({ "reason": body.reason }),
    )
    .await?;

    crate::notify::send(
        &st.nats,
        user_id,
        saarathi_core::domain::notif::TRANSACTIONAL,
        "KYC needs another look",
        &format!("Your driver verification wasn't approved: {}", body.reason),
        None,
    )
    .await;

    Ok(Json(json!({ "ok": true, "kyc_status": "rejected" })))
}

/// Suspends the driver's underlying account (blocks login — same
/// verify_otp/refresh status check every account goes through) and forces
/// them offline so they stop receiving dispatch offers immediately rather
/// than waiting out the presence TTL. Doesn't touch kyc_status — an approved
/// driver stays approved, just locked out, so reactivating doesn't require
/// re-review.
pub(super) async fn suspend_driver(
    State(st): State<AppState>,
    AdminUser(claims): AdminUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let mut tx = st.db.begin().await?;
    let user_id: Option<Uuid> = sqlx::query_scalar(
        "UPDATE users SET status = 'suspended' \
         WHERE id = (SELECT user_id FROM drivers WHERE id = $1) RETURNING id",
    )
    .bind(id)
    .fetch_optional(&mut *tx)
    .await?;
    let user_id = user_id.ok_or(AppError::NotFound)?;
    sqlx::query("UPDATE drivers SET is_online = false WHERE id = $1")
        .bind(id)
        .execute(&mut *tx)
        .await?;

    audit::record(
        &st.db,
        claims.sub,
        "driver.suspend",
        "driver",
        id,
        json!({}),
    )
    .await?;
    tx.commit().await?;

    crate::notify::send(
        &st.nats,
        user_id,
        saarathi_core::domain::notif::TRANSACTIONAL,
        "Account suspended",
        "Your Saarathi account has been suspended. Contact support if you believe this is a mistake.",
        None,
    )
    .await;
    crate::notify::publish_status_changed(
        &st.nats,
        user_id,
        saarathi_core::domain::user_status::SUSPENDED,
    )
    .await;

    Ok(Json(json!({ "ok": true, "status": "suspended" })))
}

pub(super) async fn reactivate_driver(
    State(st): State<AppState>,
    AdminUser(claims): AdminUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let user_id: Option<Uuid> = sqlx::query_scalar(
        "UPDATE users SET status = 'active' \
         WHERE id = (SELECT user_id FROM drivers WHERE id = $1) RETURNING id",
    )
    .bind(id)
    .fetch_optional(&st.db)
    .await?;
    let user_id = user_id.ok_or(AppError::NotFound)?;

    audit::record(
        &st.db,
        claims.sub,
        "driver.reactivate",
        "driver",
        id,
        json!({}),
    )
    .await?;

    crate::notify::send(
        &st.nats,
        user_id,
        saarathi_core::domain::notif::TRANSACTIONAL,
        "Account reactivated",
        "Your Saarathi account is active again — you can sign in and go online.",
        None,
    )
    .await;
    crate::notify::publish_status_changed(
        &st.nats,
        user_id,
        saarathi_core::domain::user_status::ACTIVE,
    )
    .await;

    Ok(Json(json!({ "ok": true, "status": "active" })))
}

#[derive(Deserialize)]
pub(super) struct ServiceTypesInput {
    service_types: Vec<String>,
}

/// Staff override of a driver's declared service type (ride or delivery) —
/// the same field the driver themselves sets at KYC (`POST
/// /v1/driver/register`) and that the app re-reads before every `goOnline`,
/// so this takes effect the next time the driver comes online.
pub(super) async fn update_service_types(
    State(st): State<AppState>,
    AdminUser(claims): AdminUser,
    Path(id): Path<Uuid>,
    Json(body): Json<ServiceTypesInput>,
) -> AppResult<Json<Value>> {
    let service_types =
        crate::routes::driver_routes::validate_service_types(Some(body.service_types))?;

    let updated = sqlx::query("UPDATE drivers SET service_types = $2 WHERE id = $1")
        .bind(id)
        .bind(&service_types)
        .execute(&st.db)
        .await?;
    if updated.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }

    audit::record(
        &st.db,
        claims.sub,
        "driver.service_types.update",
        "driver",
        id,
        json!({ "service_types": service_types }),
    )
    .await?;

    Ok(Json(json!({ "ok": true, "service_types": service_types })))
}

#[derive(Deserialize)]
pub(super) struct UpdateDriverVehicle {
    make: Option<String>,
    model: Option<String>,
    year: Option<i32>,
    plate_number: Option<String>,
    color: Option<String>,
}

#[derive(Deserialize)]
pub(super) struct UpdateDriverInput {
    full_name: Option<String>,
    license_number: Option<String>,
    date_of_birth: Option<NaiveDate>,
    address: Option<String>,
    vehicle: Option<UpdateDriverVehicle>,
}

/// Staff correction of a driver's own details and vehicle — typo fixes, not
/// KYC review (that stays on `approve`/`reject`) and not the service-types
/// toggle (that has its own endpoint above).
pub(super) async fn update_driver(
    State(st): State<AppState>,
    AdminUser(claims): AdminUser,
    Path(id): Path<Uuid>,
    Json(body): Json<UpdateDriverInput>,
) -> AppResult<Json<Driver>> {
    if let Some(name) = &body.full_name
        && name.trim().is_empty()
    {
        return Err(AppError::BadRequest("full_name cannot be empty".into()));
    }
    if let Some(license) = &body.license_number
        && license.trim().is_empty()
    {
        return Err(AppError::BadRequest(
            "license_number cannot be empty".into(),
        ));
    }
    if let Some(address) = &body.address
        && address.trim().is_empty()
    {
        return Err(AppError::BadRequest("address cannot be empty".into()));
    }
    if let Some(v) = &body.vehicle {
        if let Some(plate) = &v.plate_number
            && plate.trim().is_empty()
        {
            return Err(AppError::BadRequest("plate_number cannot be empty".into()));
        }
        if let Some(model) = &v.model
            && model.trim().is_empty()
        {
            return Err(AppError::BadRequest("model cannot be empty".into()));
        }
    }
    let full_name = body.full_name.as_deref().map(str::trim);

    let mut tx = st.db.begin().await?;

    let driver: Driver = sqlx::query_as(
        "UPDATE drivers SET \
             license_number = COALESCE($2, license_number), \
             date_of_birth = COALESCE($3, date_of_birth), \
             address = COALESCE($4, address) \
         WHERE id = $1 \
         RETURNING id, user_id, kyc_status, license_number, date_of_birth, address, \
                   rejection_reason, reviewed_by, reviewed_at, approved_at, service_types, created_at, updated_at",
    )
    .bind(id)
    .bind(body.license_number)
    .bind(body.date_of_birth)
    .bind(body.address)
    .fetch_optional(&mut *tx)
    .await?
    .ok_or(AppError::NotFound)?;

    if full_name.is_some() {
        sqlx::query("UPDATE users SET full_name = COALESCE($2, full_name) WHERE id = $1")
            .bind(driver.user_id)
            .bind(full_name)
            .execute(&mut *tx)
            .await?;
    }

    if let Some(v) = &body.vehicle {
        sqlx::query(
            "UPDATE vehicles SET \
                 make = COALESCE($2, make), \
                 model = COALESCE($3, model), \
                 year = COALESCE($4, year), \
                 plate_number = COALESCE($5, plate_number), \
                 color = COALESCE($6, color) \
             WHERE driver_id = $1",
        )
        .bind(id)
        .bind(&v.make)
        .bind(&v.model)
        .bind(v.year)
        .bind(v.plate_number.as_deref().map(str::trim))
        .bind(&v.color)
        .execute(&mut *tx)
        .await?;
    }

    audit::record(
        &st.db,
        claims.sub,
        "driver.update",
        "driver",
        id,
        json!({
            "full_name": full_name,
            "license_number": driver.license_number,
            "date_of_birth": driver.date_of_birth,
            "address": driver.address,
        }),
    )
    .await?;

    tx.commit().await?;
    Ok(Json(driver))
}

// ── On-site KYC entry (staff onboards a walk-in driver) ────────────────────

#[derive(Deserialize)]
pub(super) struct OnboardVehicle {
    class: VehicleWheelerClass,
    make: Option<String>,
    model: Option<String>,
    year: Option<i32>,
    plate_number: String,
    color: Option<String>,
}

#[derive(Deserialize)]
pub(super) struct OnboardInput {
    phone: String,
    full_name: Option<String>,
    license_number: Option<String>,
    date_of_birth: Option<NaiveDate>,
    address: Option<String>,
    vehicle: OnboardVehicle,
    /// Job types this driver accepts — same field the self-serve app KYC
    /// form sets (see `driver_routes::RegisterInput`); defaults to ride-only
    /// when omitted.
    service_types: Option<Vec<String>>,
}

/// Staff captures a driver's KYC on-site (walk-in): creates/promotes the user,
/// their driver profile, and vehicle in one shot. The driver lands in the
/// review queue (documents can then be uploaded on their behalf and approved).
pub(super) async fn onboard_driver(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Json(body): Json<OnboardInput>,
) -> AppResult<Json<Driver>> {
    if !claims.can_review_kyc() {
        return Err(AppError::Forbidden);
    }
    let phone = body.phone.trim();
    if phone.is_empty() {
        return Err(AppError::BadRequest("phone is required".into()));
    }
    if body.full_name.as_deref().unwrap_or("").trim().is_empty() {
        return Err(AppError::BadRequest("full_name is required".into()));
    }
    if body
        .license_number
        .as_deref()
        .unwrap_or("")
        .trim()
        .is_empty()
    {
        return Err(AppError::BadRequest("license_number is required".into()));
    }
    if body.address.as_deref().unwrap_or("").trim().is_empty() {
        return Err(AppError::BadRequest("address is required".into()));
    }
    if body.vehicle.plate_number.trim().is_empty() {
        return Err(AppError::BadRequest(
            "vehicle plate_number is required".into(),
        ));
    }
    if body
        .vehicle
        .model
        .as_deref()
        .unwrap_or("")
        .trim()
        .is_empty()
    {
        return Err(AppError::BadRequest("vehicle model is required".into()));
    }
    let service_types = crate::routes::driver_routes::validate_service_types(body.service_types)?;

    let mut tx = st.db.begin().await?;

    // Create or find the user, promoting a plain rider to a driver.
    let user_id: Uuid = sqlx::query_scalar(
        "INSERT INTO users (phone, full_name, role, status) VALUES ($1, $2, 'driver', 'pending') \
         ON CONFLICT (phone) DO UPDATE SET \
             full_name = COALESCE(EXCLUDED.full_name, users.full_name), \
             role = CASE WHEN users.role = 'rider' THEN 'driver'::user_role ELSE users.role END \
         RETURNING id",
    )
    .bind(phone)
    .bind(body.full_name.as_deref())
    .fetch_one(&mut *tx)
    .await?;

    let driver: Driver = sqlx::query_as(
        "INSERT INTO drivers (user_id, license_number, date_of_birth, address, kyc_status, onboarded_by, service_types) \
         VALUES ($1, $2, $3, $4, 'under_review', $5, $6) \
         ON CONFLICT (user_id) DO UPDATE SET \
             license_number = EXCLUDED.license_number, \
             date_of_birth = EXCLUDED.date_of_birth, \
             address = EXCLUDED.address, \
             onboarded_by = EXCLUDED.onboarded_by, \
             service_types = EXCLUDED.service_types \
         RETURNING id, user_id, kyc_status, license_number, date_of_birth, address, \
                   rejection_reason, reviewed_by, reviewed_at, approved_at, service_types, created_at, updated_at",
    )
    .bind(user_id)
    .bind(body.license_number)
    .bind(body.date_of_birth)
    .bind(body.address)
    .bind(claims.sub)
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
    .bind(body.vehicle.plate_number.trim())
    .bind(body.vehicle.color)
    .execute(&mut *tx)
    .await?;

    audit::record(
        &st.db,
        claims.sub,
        "driver.onboard",
        "driver",
        driver.id,
        json!({ "phone": phone }),
    )
    .await?;
    tx.commit().await?;
    Ok(Json(driver))
}
