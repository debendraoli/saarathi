//! Staff dashboard endpoints: driver verification queue, decisions, document
//! viewing. All decisions are audit-logged and role-gated (RBAC).

use crate::audit;
use crate::error::{AppError, AppResult};
use crate::models::{
    DocumentKind, Driver, DriverDocument, User, UserRole, UserStatus, Vehicle, VehicleWheelerClass,
};
use crate::state::{AdminUser, AppState, StaffUser};
use axum::extract::{Multipart, Path, Query, State};
use axum::http::header;
use axum::response::{IntoResponse, Response};
use axum::{
    routing::{get, patch, post},
    Json, Router,
};
use chrono::NaiveDate;
use saarathi_core::api::ErrorCode;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/admin/drivers", get(list_drivers))
        .route("/v1/admin/drivers/onboard", post(onboard_driver))
        .route("/v1/admin/drivers/{id}", get(driver_detail))
        .route("/v1/admin/drivers/{id}/approve", post(approve_driver))
        .route("/v1/admin/drivers/{id}/reject", post(reject_driver))
        .route("/v1/admin/drivers/{id}/suspend", post(suspend_driver))
        .route("/v1/admin/drivers/{id}/reactivate", post(reactivate_driver))
        .route(
            "/v1/admin/drivers/{id}/documents",
            post(upload_driver_document),
        )
        .route("/v1/admin/documents/{id}/content", get(document_content))
        .route("/v1/admin/staff", get(list_staff).post(create_staff))
        .route("/v1/admin/staff/{id}", patch(update_staff))
        .route("/v1/admin/staff/{id}/deactivate", post(deactivate_staff))
        .route("/v1/admin/staff/{id}/reactivate", post(reactivate_staff))
}

/// Non-rider/non-driver roles — the only ones a staff account may hold.
fn is_staff_role(role: UserRole) -> bool {
    !matches!(role, UserRole::Rider | UserRole::Driver)
}

#[derive(Deserialize)]
struct ListQuery {
    status: Option<String>,
}

#[derive(Serialize, sqlx::FromRow)]
struct DriverListItem {
    id: Uuid,
    user_id: Uuid,
    kyc_status: crate::models::KycStatus,
    full_name: Option<String>,
    phone: String,
    license_number: Option<String>,
    created_at: chrono::DateTime<chrono::Utc>,
    reviewed_at: Option<chrono::DateTime<chrono::Utc>>,
}

async fn list_drivers(
    State(st): State<AppState>,
    _staff: StaffUser,
    Query(q): Query<ListQuery>,
) -> AppResult<Json<Vec<DriverListItem>>> {
    // Default to the actionable queue — `pending` means the driver hasn't
    // finished uploading documents and submitted yet (see POST
    // /v1/driver/kyc/submit), so it's deliberately excluded here.
    let status_filter = q.status.unwrap_or_else(|| "queue".into());

    let base = "SELECT d.id, d.user_id, d.kyc_status, u.full_name, u.phone, \
                d.license_number, d.created_at, d.reviewed_at \
                FROM drivers d JOIN users u ON u.id = d.user_id ";

    let items: Vec<DriverListItem> = if status_filter == "queue" {
        sqlx::query_as(&format!(
            "{base} WHERE d.kyc_status = 'under_review' ORDER BY d.created_at",
        ))
        .fetch_all(&st.db)
        .await?
    } else {
        sqlx::query_as(&format!(
            "{base} WHERE d.kyc_status::text = $1 ORDER BY d.created_at DESC"
        ))
        .bind(&status_filter)
        .fetch_all(&st.db)
        .await?
    };

    Ok(Json(items))
}

#[derive(Serialize)]
struct DriverDetail {
    driver: Driver,
    user: User,
    vehicle: Option<Vehicle>,
    documents: Vec<DriverDocument>,
}

async fn driver_detail(
    State(st): State<AppState>,
    _staff: StaffUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<DriverDetail>> {
    let driver: Driver = sqlx::query_as(
        "SELECT id, user_id, kyc_status, license_number, date_of_birth, address, \
                rejection_reason, reviewed_by, reviewed_at, approved_at, created_at, updated_at \
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

async fn approve_driver(
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
struct RejectInput {
    reason: String,
}

async fn reject_driver(
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
async fn suspend_driver(
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

    Ok(Json(json!({ "ok": true, "status": "suspended" })))
}

async fn reactivate_driver(
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

    Ok(Json(json!({ "ok": true, "status": "active" })))
}

// ── On-site KYC entry (staff onboards a walk-in driver) ────────────────────

#[derive(Deserialize)]
struct OnboardVehicle {
    class: VehicleWheelerClass,
    make: Option<String>,
    model: Option<String>,
    year: Option<i32>,
    plate_number: String,
    color: Option<String>,
}

#[derive(Deserialize)]
struct OnboardInput {
    phone: String,
    full_name: Option<String>,
    license_number: Option<String>,
    date_of_birth: Option<NaiveDate>,
    address: Option<String>,
    vehicle: OnboardVehicle,
}

/// Staff captures a driver's KYC on-site (walk-in): creates/promotes the user,
/// their driver profile, and vehicle in one shot. The driver lands in the
/// review queue (documents can then be uploaded on their behalf and approved).
async fn onboard_driver(
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
    if body.vehicle.plate_number.trim().is_empty() {
        return Err(AppError::BadRequest(
            "vehicle plate_number is required".into(),
        ));
    }

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
        "INSERT INTO drivers (user_id, license_number, date_of_birth, address, kyc_status, onboarded_by) \
         VALUES ($1, $2, $3, $4, 'under_review', $5) \
         ON CONFLICT (user_id) DO UPDATE SET \
             license_number = EXCLUDED.license_number, \
             date_of_birth = EXCLUDED.date_of_birth, \
             address = EXCLUDED.address, \
             onboarded_by = EXCLUDED.onboarded_by \
         RETURNING id, user_id, kyc_status, license_number, date_of_birth, address, \
                   rejection_reason, reviewed_by, reviewed_at, approved_at, created_at, updated_at",
    )
    .bind(user_id)
    .bind(body.license_number)
    .bind(body.date_of_birth)
    .bind(body.address)
    .bind(claims.sub)
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

/// Staff uploads a KYC document on a walk-in driver's behalf.
async fn upload_driver_document(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Path(driver_id): Path<Uuid>,
    mut multipart: Multipart,
) -> AppResult<Json<DriverDocument>> {
    if !claims.can_review_kyc() {
        return Err(AppError::Forbidden);
    }
    // Confirm the driver exists.
    let exists: Option<(Uuid,)> = sqlx::query_as("SELECT id FROM drivers WHERE id = $1")
        .bind(driver_id)
        .fetch_optional(&st.db)
        .await?;
    if exists.is_none() {
        return Err(AppError::NotFound);
    }

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
                kind = Some(parse_document_kind(&text)?);
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

    audit::record(
        &st.db,
        claims.sub,
        "driver.document.upload",
        "driver",
        driver_id,
        json!({}),
    )
    .await?;
    Ok(Json(doc))
}

fn parse_document_kind(s: &str) -> Result<DocumentKind, AppError> {
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
                saarathi_core::api::ErrorCode::DocumentInvalid,
                format!("unknown document kind '{other}'"),
            ))
        }
    })
}

async fn document_content(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Path(id): Path<Uuid>,
) -> AppResult<Response> {
    let row: Option<(String, Option<String>)> =
        sqlx::query_as("SELECT storage_key, content_type FROM driver_documents WHERE id = $1")
            .bind(id)
            .fetch_optional(&st.db)
            .await?;
    let (storage_key, content_type) = row.ok_or(AppError::NotFound)?;

    let bytes = st
        .docs
        .get(&storage_key)
        .await
        .map_err(|_| AppError::NotFound)?;
    audit::record(
        &st.db,
        claims.sub,
        "document.view",
        "driver_document",
        id,
        json!({}),
    )
    .await?;

    let ct = content_type.unwrap_or_else(|| "application/octet-stream".into());
    Ok(([(header::CONTENT_TYPE, ct)], bytes).into_response())
}

// ── Staff accounts ───────────────────────────────────────────────────────
//
// A staff account is just a `users` row with a non-rider/non-driver role —
// there's no separate staff table. Creating one here only provisions the
// row; the new staff member still logs in themselves via the normal OTP
// flow (POST /v1/auth/otp/*) with their own phone, same as everyone else.

async fn list_staff(State(st): State<AppState>, _admin: AdminUser) -> AppResult<Json<Vec<User>>> {
    let staff: Vec<User> = sqlx::query_as(
        "SELECT id, phone, full_name, role, status, created_at, updated_at FROM users \
         WHERE role NOT IN ('rider', 'driver') ORDER BY created_at DESC",
    )
    .fetch_all(&st.db)
    .await?;
    Ok(Json(staff))
}

#[derive(Deserialize)]
struct CreateStaffRequest {
    phone: String,
    full_name: String,
    role: UserRole,
}

async fn create_staff(
    State(st): State<AppState>,
    AdminUser(claims): AdminUser,
    Json(body): Json<CreateStaffRequest>,
) -> AppResult<Json<User>> {
    if !crate::otp::valid_phone(&body.phone) {
        return Err(AppError::bad(
            ErrorCode::PhoneInvalid,
            "phone must be E.164, e.g. +9779800000000",
        ));
    }
    if !is_staff_role(body.role) {
        return Err(AppError::bad(
            ErrorCode::Validation,
            "role must be a staff role, not rider/driver",
        ));
    }
    if body.full_name.trim().is_empty() {
        return Err(AppError::bad(
            ErrorCode::Validation,
            "full_name is required",
        ));
    }

    let existing: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM users WHERE phone = $1)")
        .bind(&body.phone)
        .fetch_one(&st.db)
        .await?;
    if existing {
        return Err(AppError::conflict(
            ErrorCode::Conflict,
            "a user with this phone already exists",
        ));
    }

    let staff: User = sqlx::query_as(
        "INSERT INTO users (phone, full_name, role, status) VALUES ($1, $2, $3, 'active') \
         RETURNING id, phone, full_name, role, status, created_at, updated_at",
    )
    .bind(&body.phone)
    .bind(body.full_name.trim())
    .bind(body.role)
    .fetch_one(&st.db)
    .await?;

    audit::record(
        &st.db,
        claims.sub,
        "staff.create",
        "user",
        staff.id,
        json!({ "role": body.role }),
    )
    .await?;
    Ok(Json(staff))
}

#[derive(Deserialize)]
struct UpdateStaffRequest {
    role: Option<UserRole>,
    full_name: Option<String>,
}

async fn update_staff(
    State(st): State<AppState>,
    AdminUser(claims): AdminUser,
    Path(id): Path<Uuid>,
    Json(body): Json<UpdateStaffRequest>,
) -> AppResult<Json<User>> {
    if let Some(role) = body.role {
        if !is_staff_role(role) {
            return Err(AppError::bad(
                ErrorCode::Validation,
                "role must be a staff role, not rider/driver",
            ));
        }
        // A staff member can't change their own role — avoids self-lockout
        // (e.g. accidentally demoting the only admin who could undo it).
        if id == claims.sub {
            return Err(AppError::Forbidden);
        }
    }
    if let Some(name) = &body.full_name {
        if name.trim().is_empty() {
            return Err(AppError::bad(
                ErrorCode::Validation,
                "full_name cannot be empty",
            ));
        }
    }

    let current: Option<(UserRole,)> = sqlx::query_as("SELECT role FROM users WHERE id = $1")
        .bind(id)
        .fetch_optional(&st.db)
        .await?;
    let (current_role,) = current.ok_or(AppError::NotFound)?;
    if !is_staff_role(current_role) {
        return Err(AppError::NotFound); // not a staff account — don't let this endpoint touch riders/drivers
    }

    let staff: User = sqlx::query_as(
        "UPDATE users SET role = COALESCE($2, role), full_name = COALESCE($3, full_name) \
         WHERE id = $1 \
         RETURNING id, phone, full_name, role, status, created_at, updated_at",
    )
    .bind(id)
    .bind(body.role)
    .bind(body.full_name.as_deref().map(str::trim))
    .fetch_one(&st.db)
    .await?;

    audit::record(
        &st.db,
        claims.sub,
        "staff.update",
        "user",
        id,
        json!({ "role": body.role }),
    )
    .await?;
    Ok(Json(staff))
}

async fn set_staff_status(
    st: &AppState,
    claims: &saarathi_core::authn::Claims,
    id: Uuid,
    status: UserStatus,
    action: &str,
) -> AppResult<Json<User>> {
    if id == claims.sub {
        return Err(AppError::Forbidden);
    }
    let current: Option<(UserRole,)> = sqlx::query_as("SELECT role FROM users WHERE id = $1")
        .bind(id)
        .fetch_optional(&st.db)
        .await?;
    let (current_role,) = current.ok_or(AppError::NotFound)?;
    if !is_staff_role(current_role) {
        return Err(AppError::NotFound);
    }

    let staff: User = sqlx::query_as(
        "UPDATE users SET status = $2 WHERE id = $1 \
         RETURNING id, phone, full_name, role, status, created_at, updated_at",
    )
    .bind(id)
    .bind(status)
    .fetch_one(&st.db)
    .await?;

    audit::record(&st.db, claims.sub, action, "user", id, json!({})).await?;
    Ok(Json(staff))
}

async fn deactivate_staff(
    State(st): State<AppState>,
    AdminUser(claims): AdminUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<User>> {
    set_staff_status(&st, &claims, id, UserStatus::Suspended, "staff.deactivate").await
}

async fn reactivate_staff(
    State(st): State<AppState>,
    AdminUser(claims): AdminUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<User>> {
    set_staff_status(&st, &claims, id, UserStatus::Active, "staff.reactivate").await
}
