//! Partner-scoped portal: a partner's own staff manage their members and fleet
//! drivers. Every route resolves the caller's membership for the path
//! `partner_id` and checks their `partner_role` — hard tenant isolation.

use crate::audit;
use crate::error::{AppError, AppResult};
use crate::models::{PartnerRole, PartnerStatus, VehicleClass};
use crate::state::{AppState, AuthUser};
use axum::extract::{Path, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use saarathi_core::api::ErrorCode;
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/partner/memberships", get(memberships))
        .route(
            "/v1/partner/{pid}/members",
            get(list_members).post(invite_member),
        )
        .route(
            "/v1/partner/{pid}/members/{uid}",
            post(set_member_role).delete(remove_member),
        )
        .route(
            "/v1/partner/{pid}/drivers",
            get(list_drivers).post(add_driver),
        )
        .route(
            "/v1/partner/{pid}/drivers/{driver_user_id}",
            post(set_driver_status),
        )
        .route("/v1/partner/{pid}/riders", get(list_riders).post(add_rider))
        .route(
            "/v1/partner/{pid}/riders/{rider_user_id}",
            post(set_rider_status),
        )
}

/// Resolve the caller's active membership + confirm the partner is active.
async fn require_member(
    db: &sqlx::PgPool,
    user_id: Uuid,
    partner_id: Uuid,
) -> AppResult<PartnerRole> {
    let row: Option<(PartnerRole, PartnerStatus)> = sqlx::query_as(
        "SELECT pm.role, p.status FROM partner_members pm JOIN partners p ON p.id = pm.partner_id \
         WHERE pm.partner_id = $1 AND pm.user_id = $2 AND pm.status = 'active'",
    )
    .bind(partner_id)
    .bind(user_id)
    .fetch_optional(db)
    .await?;
    let (role, status) = row.ok_or(AppError::Forbidden)?;
    if !matches!(status, PartnerStatus::Active) {
        return Err(AppError::forbidden(
            ErrorCode::PartnerSuspended,
            "partner is not active",
        ));
    }
    Ok(role)
}

#[derive(Serialize, sqlx::FromRow)]
struct Membership {
    partner_id: Uuid,
    name: String,
    role: PartnerRole,
    status: PartnerStatus,
}

async fn memberships(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Vec<Membership>>> {
    let rows: Vec<Membership> = sqlx::query_as(
        "SELECT p.id AS partner_id, p.name, pm.role, p.status \
         FROM partner_members pm JOIN partners p ON p.id = pm.partner_id \
         WHERE pm.user_id = $1 AND pm.status = 'active' ORDER BY p.created_at",
    )
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Serialize, sqlx::FromRow)]
struct MemberRow {
    user_id: Uuid,
    phone: String,
    full_name: Option<String>,
    role: PartnerRole,
    created_at: DateTime<Utc>,
}

async fn list_members(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
) -> AppResult<Json<Vec<MemberRow>>> {
    require_member(&st.db, claims.sub, pid).await?;
    let rows: Vec<MemberRow> = sqlx::query_as(
        "SELECT pm.user_id, u.phone, u.full_name, pm.role, pm.created_at \
         FROM partner_members pm JOIN users u ON u.id = pm.user_id \
         WHERE pm.partner_id = $1 AND pm.status = 'active' ORDER BY pm.created_at",
    )
    .bind(pid)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
struct InviteMember {
    phone: String,
    role: String,
}

fn valid_role(s: &str) -> bool {
    matches!(
        s,
        "owner" | "admin" | "manager" | "dispatcher" | "finance" | "support" | "viewer"
    )
}

async fn invite_member(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
    Json(body): Json<InviteMember>,
) -> AppResult<Json<MemberRow>> {
    let my_role = require_member(&st.db, claims.sub, pid).await?;
    if !my_role.can_manage_members() {
        return Err(AppError::Forbidden);
    }
    let phone = body.phone.trim();
    if phone.is_empty() || !valid_role(&body.role) {
        return Err(AppError::BadRequest(
            "phone and a valid role are required".into(),
        ));
    }

    let mut tx = st.db.begin().await?;
    let user_id: Uuid = sqlx::query_scalar(
        "INSERT INTO users (phone, role, status) VALUES ($1, 'rider', 'active') \
         ON CONFLICT (phone) DO UPDATE SET phone = EXCLUDED.phone RETURNING id",
    )
    .bind(phone)
    .fetch_one(&mut *tx)
    .await?;
    let member: MemberRow = sqlx::query_as(
        "INSERT INTO partner_members (partner_id, user_id, role, invited_by) \
         VALUES ($1, $2, $3::partner_role, $4) \
         ON CONFLICT (partner_id, user_id) DO UPDATE SET role = EXCLUDED.role, status = 'active' \
         RETURNING user_id, \
             (SELECT phone FROM users WHERE id = partner_members.user_id) AS phone, \
             (SELECT full_name FROM users WHERE id = partner_members.user_id) AS full_name, \
             role, created_at",
    )
    .bind(pid)
    .bind(user_id)
    .bind(&body.role)
    .bind(claims.sub)
    .fetch_one(&mut *tx)
    .await?;
    audit_partner(&mut tx, claims.sub, pid, "partner.member.invite", user_id).await?;
    tx.commit().await?;
    Ok(Json(member))
}

#[derive(Deserialize)]
struct SetRole {
    role: String,
}

async fn set_member_role(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path((pid, uid)): Path<(Uuid, Uuid)>,
    Json(body): Json<SetRole>,
) -> AppResult<Json<serde_json::Value>> {
    let my_role = require_member(&st.db, claims.sub, pid).await?;
    if !my_role.can_manage_members() || !valid_role(&body.role) {
        return Err(AppError::Forbidden);
    }
    // Don't allow demoting the last owner.
    if body.role != "owner" {
        guard_last_owner(&st.db, pid, uid).await?;
    }
    let res = sqlx::query(
        "UPDATE partner_members SET role = $3::partner_role, updated_at = now() \
         WHERE partner_id = $1 AND user_id = $2",
    )
    .bind(pid)
    .bind(uid)
    .bind(&body.role)
    .execute(&st.db)
    .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    let _ = audit::record(
        &st.db,
        claims.sub,
        "partner.member.role",
        "partner",
        pid,
        json!({ "user_id": uid, "role": body.role }),
    )
    .await;
    Ok(Json(json!({ "ok": true })))
}

async fn remove_member(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path((pid, uid)): Path<(Uuid, Uuid)>,
) -> AppResult<Json<serde_json::Value>> {
    let my_role = require_member(&st.db, claims.sub, pid).await?;
    if !my_role.can_manage_members() {
        return Err(AppError::Forbidden);
    }
    guard_last_owner(&st.db, pid, uid).await?;
    let res = sqlx::query(
        "UPDATE partner_members SET status = 'banned', updated_at = now() \
         WHERE partner_id = $1 AND user_id = $2",
    )
    .bind(pid)
    .bind(uid)
    .execute(&st.db)
    .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(Json(json!({ "ok": true })))
}

/// Block an action that would leave the partner with no active owner.
async fn guard_last_owner(db: &sqlx::PgPool, pid: Uuid, target: Uuid) -> AppResult<()> {
    let target_is_owner: Option<(PartnerRole,)> = sqlx::query_as(
        "SELECT role FROM partner_members WHERE partner_id = $1 AND user_id = $2 AND status = 'active'",
    )
    .bind(pid)
    .bind(target)
    .fetch_optional(db)
    .await?;
    if matches!(target_is_owner, Some((PartnerRole::Owner,))) {
        let owners: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM partner_members WHERE partner_id = $1 AND role = 'owner' AND status = 'active'",
        )
        .bind(pid)
        .fetch_one(db)
        .await?;
        if owners <= 1 {
            return Err(AppError::BadRequest(
                "a partner must keep at least one owner".into(),
            ));
        }
    }
    Ok(())
}

// ── Fleet drivers ───────────────────────────────────────────────────────────

#[derive(Serialize, sqlx::FromRow)]
struct FleetDriver {
    driver_user_id: Uuid,
    phone: String,
    full_name: Option<String>,
    status: String,
    kyc_status: Option<String>,
    joined_at: DateTime<Utc>,
}

async fn list_drivers(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
) -> AppResult<Json<Vec<FleetDriver>>> {
    require_member(&st.db, claims.sub, pid).await?;
    let rows: Vec<FleetDriver> = sqlx::query_as(
        "SELECT pd.driver_user_id, u.phone, u.full_name, pd.status::text AS status, \
                d.kyc_status::text AS kyc_status, pd.joined_at \
         FROM partner_drivers pd JOIN users u ON u.id = pd.driver_user_id \
         LEFT JOIN drivers d ON d.user_id = pd.driver_user_id \
         WHERE pd.partner_id = $1 AND pd.status <> 'left' ORDER BY pd.joined_at DESC",
    )
    .bind(pid)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
struct AddDriver {
    phone: String,
    full_name: Option<String>,
    license_number: Option<String>,
    vehicle_class: Option<VehicleClass>,
    plate_number: Option<String>,
}

async fn add_driver(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
    Json(body): Json<AddDriver>,
) -> AppResult<Json<serde_json::Value>> {
    let my_role = require_member(&st.db, claims.sub, pid).await?;
    if !my_role.can_manage_drivers() {
        return Err(AppError::Forbidden);
    }
    let phone = body.phone.trim();
    if phone.is_empty() {
        return Err(AppError::BadRequest("phone is required".into()));
    }

    let mut tx = st.db.begin().await?;
    // Find or create the driver's user account (promote a plain rider to driver).
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

    // Ensure a driver profile exists (KYC starts pending; staff can approve later).
    let driver_id: Uuid = sqlx::query_scalar(
        "INSERT INTO drivers (user_id, license_number, kyc_status) VALUES ($1, $2, 'pending') \
         ON CONFLICT (user_id) DO UPDATE SET \
             license_number = COALESCE(EXCLUDED.license_number, drivers.license_number) \
         RETURNING id",
    )
    .bind(user_id)
    .bind(body.license_number)
    .fetch_one(&mut *tx)
    .await?;

    // Optional vehicle capture.
    if let (Some(class), Some(plate)) = (body.vehicle_class, body.plate_number.as_deref()) {
        if !plate.trim().is_empty() {
            sqlx::query(
                "INSERT INTO vehicles (driver_id, class, plate_number) VALUES ($1, $2, $3)",
            )
            .bind(driver_id)
            .bind(class)
            .bind(plate.trim())
            .execute(&mut *tx)
            .await?;
        }
    }

    // Link to the fleet (one active fleet per driver).
    let linked = sqlx::query(
        "INSERT INTO partner_drivers (partner_id, driver_user_id, invited_by) VALUES ($1, $2, $3)",
    )
    .bind(pid)
    .bind(user_id)
    .bind(claims.sub)
    .execute(&mut *tx)
    .await;
    if let Err(sqlx::Error::Database(db)) = &linked {
        if db.is_unique_violation() {
            return Err(AppError::conflict(
                ErrorCode::DriverAlreadyInFleet,
                "this driver is already active in a fleet",
            ));
        }
    }
    linked?;

    audit_partner(&mut tx, claims.sub, pid, "partner.driver.add", user_id).await?;
    tx.commit().await?;
    Ok(Json(
        json!({ "driver_user_id": user_id, "status": "active" }),
    ))
}

#[derive(Deserialize)]
struct SetDriverStatus {
    status: String, // active | suspended | left
}

async fn set_driver_status(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path((pid, driver_user_id)): Path<(Uuid, Uuid)>,
    Json(body): Json<SetDriverStatus>,
) -> AppResult<Json<serde_json::Value>> {
    let my_role = require_member(&st.db, claims.sub, pid).await?;
    if !my_role.can_manage_drivers() {
        return Err(AppError::Forbidden);
    }
    if !matches!(body.status.as_str(), "active" | "suspended" | "left") {
        return Err(AppError::BadRequest("invalid status".into()));
    }
    let res = sqlx::query(
        "UPDATE partner_drivers SET status = $3::partner_driver_status, \
            left_at = CASE WHEN $3 = 'left' THEN now() ELSE left_at END \
         WHERE partner_id = $1 AND driver_user_id = $2 AND status <> 'left'",
    )
    .bind(pid)
    .bind(driver_user_id)
    .bind(&body.status)
    .execute(&st.db)
    .await
    .map_err(|e| match e {
        sqlx::Error::Database(db) if db.is_unique_violation() => AppError::conflict(
            ErrorCode::DriverAlreadyInFleet,
            "this driver is already active in a fleet",
        ),
        other => AppError::Db(other),
    })?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(Json(json!({ "ok": true, "status": body.status })))
}

// ── Corporate rider tabs (ride-on-company-tab) ──────────────────────────────

#[derive(Serialize, sqlx::FromRow)]
struct FleetRider {
    rider_user_id: Uuid,
    phone: String,
    full_name: Option<String>,
    status: String,
    monthly_cap: Option<rust_decimal::Decimal>,
    joined_at: DateTime<Utc>,
}

async fn list_riders(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
) -> AppResult<Json<Vec<FleetRider>>> {
    require_member(&st.db, claims.sub, pid).await?;
    let rows: Vec<FleetRider> = sqlx::query_as(
        "SELECT pr.rider_user_id, u.phone, u.full_name, pr.status, pr.monthly_cap, pr.joined_at \
         FROM partner_riders pr JOIN users u ON u.id = pr.rider_user_id \
         WHERE pr.partner_id = $1 AND pr.status <> 'left' ORDER BY pr.joined_at DESC",
    )
    .bind(pid)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
struct AddRider {
    phone: String,
    full_name: Option<String>,
    monthly_cap: Option<rust_decimal::Decimal>,
}

async fn add_rider(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
    Json(body): Json<AddRider>,
) -> AppResult<Json<serde_json::Value>> {
    let my_role = require_member(&st.db, claims.sub, pid).await?;
    if !my_role.can_manage_drivers() {
        return Err(AppError::Forbidden);
    }
    let phone = body.phone.trim();
    if phone.is_empty() {
        return Err(AppError::BadRequest("phone is required".into()));
    }
    let mut tx = st.db.begin().await?;
    let user_id: Uuid = sqlx::query_scalar(
        "INSERT INTO users (phone, full_name, role, status) VALUES ($1, $2, 'rider', 'active') \
         ON CONFLICT (phone) DO UPDATE SET full_name = COALESCE(EXCLUDED.full_name, users.full_name) \
         RETURNING id",
    )
    .bind(phone)
    .bind(body.full_name.as_deref())
    .fetch_one(&mut *tx)
    .await?;
    let linked = sqlx::query(
        "INSERT INTO partner_riders (partner_id, rider_user_id, monthly_cap, invited_by) \
         VALUES ($1, $2, $3, $4)",
    )
    .bind(pid)
    .bind(user_id)
    .bind(body.monthly_cap)
    .bind(claims.sub)
    .execute(&mut *tx)
    .await;
    if let Err(sqlx::Error::Database(db)) = &linked {
        if db.is_unique_violation() {
            return Err(AppError::conflict(
                ErrorCode::Conflict,
                "this rider is already on a corporate tab",
            ));
        }
    }
    linked?;
    audit_partner(&mut tx, claims.sub, pid, "partner.rider.add", user_id).await?;
    tx.commit().await?;
    Ok(Json(
        json!({ "rider_user_id": user_id, "status": "active" }),
    ))
}

#[derive(Deserialize)]
struct SetRiderStatus {
    status: String, // active | suspended | left
}

async fn set_rider_status(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path((pid, rider_user_id)): Path<(Uuid, Uuid)>,
    Json(body): Json<SetRiderStatus>,
) -> AppResult<Json<serde_json::Value>> {
    let my_role = require_member(&st.db, claims.sub, pid).await?;
    if !my_role.can_manage_drivers() {
        return Err(AppError::Forbidden);
    }
    if !matches!(body.status.as_str(), "active" | "suspended" | "left") {
        return Err(AppError::BadRequest("invalid status".into()));
    }
    let res = sqlx::query(
        "UPDATE partner_riders SET status = $3, \
            left_at = CASE WHEN $3 = 'left' THEN now() ELSE left_at END \
         WHERE partner_id = $1 AND rider_user_id = $2 AND status <> 'left'",
    )
    .bind(pid)
    .bind(rider_user_id)
    .bind(&body.status)
    .execute(&st.db)
    .await
    .map_err(|e| match e {
        sqlx::Error::Database(db) if db.is_unique_violation() => AppError::conflict(
            ErrorCode::Conflict,
            "this rider is already on a corporate tab",
        ),
        other => AppError::Db(other),
    })?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(Json(json!({ "ok": true, "status": body.status })))
}

/// Partner-scoped audit entry (records the acting partner on the row).
async fn audit_partner(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    actor: Uuid,
    partner_id: Uuid,
    action: &str,
    entity_id: Uuid,
) -> AppResult<()> {
    sqlx::query(
        "INSERT INTO audit_log (actor_user_id, action, entity_type, entity_id, partner_id) \
         VALUES ($1, $2, 'partner', $3, $4)",
    )
    .bind(actor)
    .bind(action)
    .bind(entity_id)
    .bind(partner_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}
