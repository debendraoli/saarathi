// ── Staff accounts ───────────────────────────────────────────────────────
//
// A staff account is just a `users` row with a non-rider/non-driver role —
// there's no separate staff table. Creating one here only provisions the
// row; the new staff member still logs in themselves via the normal OTP
// flow (POST /v1/auth/otp/*) with their own phone, same as everyone else.

use crate::audit;
use crate::error::{AppError, AppResult};
use crate::models::{User, UserRole, UserStatus};
use crate::state::{AdminUser, AppState};
use axum::extract::{Path, State};
use axum::Json;
use saarathi_core::api::ErrorCode;
use serde::Deserialize;
use serde_json::json;
use uuid::Uuid;

/// Non-rider/non-driver roles — the only ones a staff account may hold.
fn is_staff_role(role: UserRole) -> bool {
    !matches!(role, UserRole::Rider | UserRole::Driver)
}

pub(super) async fn list_staff(
    State(st): State<AppState>,
    _admin: AdminUser,
) -> AppResult<Json<Vec<User>>> {
    let staff: Vec<User> = sqlx::query_as(
        "SELECT id, phone, full_name, role, status, created_at, updated_at FROM users \
         WHERE role NOT IN ('rider', 'driver') ORDER BY created_at DESC",
    )
    .fetch_all(&st.db)
    .await?;
    Ok(Json(staff))
}

#[derive(Deserialize)]
pub(super) struct CreateStaffRequest {
    phone: String,
    full_name: String,
    role: UserRole,
}

pub(super) async fn create_staff(
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
pub(super) struct UpdateStaffRequest {
    role: Option<UserRole>,
    full_name: Option<String>,
}

pub(super) async fn update_staff(
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
    if let Some(name) = &body.full_name
        && name.trim().is_empty()
    {
        return Err(AppError::bad(
            ErrorCode::Validation,
            "full_name cannot be empty",
        ));
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
    crate::notify::publish_status_changed(&st.nats, id, status.wire()).await;
    Ok(Json(staff))
}

pub(super) async fn deactivate_staff(
    State(st): State<AppState>,
    AdminUser(claims): AdminUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<User>> {
    set_staff_status(&st, &claims, id, UserStatus::Suspended, "staff.deactivate").await
}

pub(super) async fn reactivate_staff(
    State(st): State<AppState>,
    AdminUser(claims): AdminUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<User>> {
    set_staff_status(&st, &claims, id, UserStatus::Active, "staff.reactivate").await
}
