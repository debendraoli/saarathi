//! Partner-scoped portal: a partner's own staff manage members, fleet drivers,
//! and corporate riders. Every route resolves the caller's membership for the
//! path `partner_id` and checks their partner role — hard tenant isolation.

use crate::audit;
use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::rbac::{
    can_manage_drivers, can_manage_members, member_role, require_member, valid_partner_role,
};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{
    Json, Router,
    routing::{get, post},
};
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use saarathi_core::api::ErrorCode;
use saarathi_core::domain::partner_roles as pr;
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

#[derive(Serialize, sqlx::FromRow)]
struct Membership {
    partner_id: Uuid,
    name: String,
    role: String,
    status: String,
}

async fn memberships(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Vec<Membership>>> {
    let rows: Vec<Membership> = sqlx::query_as(
        "SELECT p.id AS partner_id, p.name, pm.role::text AS role, p.status::text AS status \
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
    role: String,
    created_at: DateTime<Utc>,
}

async fn list_members(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
) -> AppResult<Json<Vec<MemberRow>>> {
    require_member(&st.db, claims.sub, pid).await?;
    let rows: Vec<MemberRow> = sqlx::query_as(
        "SELECT pm.user_id, u.phone, u.full_name, pm.role::text AS role, pm.created_at \
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

async fn invite_member(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
    Json(body): Json<InviteMember>,
) -> AppResult<Json<MemberRow>> {
    let my_role = member_role(&st.db, claims.sub, pid).await?;
    if !can_manage_members(&my_role) {
        return Err(AppError::Forbidden);
    }
    let phone = body.phone.trim();
    if phone.is_empty() || !valid_partner_role(&body.role) {
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
             role::text AS role, created_at",
    )
    .bind(pid)
    .bind(user_id)
    .bind(&body.role)
    .bind(claims.sub)
    .fetch_one(&mut *tx)
    .await?;
    audit::partner(&mut tx, claims.sub, pid, "partner.member.invite", user_id).await?;
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
    let my_role = member_role(&st.db, claims.sub, pid).await?;
    if !can_manage_members(&my_role) || !valid_partner_role(&body.role) {
        return Err(AppError::Forbidden);
    }
    // Don't allow demoting the last owner.
    if body.role != pr::OWNER {
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
    let my_role = member_role(&st.db, claims.sub, pid).await?;
    if !can_manage_members(&my_role) {
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
    let target_role: Option<(String,)> = sqlx::query_as(
        "SELECT role::text FROM partner_members WHERE partner_id = $1 AND user_id = $2 AND status = 'active'",
    )
    .bind(pid)
    .bind(target)
    .fetch_optional(db)
    .await?;
    if matches!(&target_role, Some((r,)) if r == pr::OWNER) {
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

/// Mirrors `saarathi-auth`'s `driver_routes::validate_service_types` — a
/// driver is exactly one of ride or delivery, never both. Duplicated (not
/// shared via a crate) because `partners` and `auth` are separate services;
/// see the same pattern for `audit_record` in `rides`/`merchant`.
fn validate_driver_service_types(input: Option<Vec<String>>) -> AppResult<Vec<String>> {
    let types = input.unwrap_or_else(|| vec!["ride".to_string()]);
    if types.len() != 1 || !matches!(types[0].as_str(), "ride" | "delivery") {
        return Err(AppError::BadRequest(
            "service_types must contain exactly one of \"ride\" or \"delivery\"".into(),
        ));
    }
    Ok(types)
}

#[derive(Deserialize)]
struct AddDriver {
    phone: String,
    full_name: Option<String>,
    license_number: Option<String>,
    address: Option<String>,
    vehicle_class: Option<String>,
    plate_number: Option<String>,
    model: Option<String>,
    /// "ride" or "delivery" — same single-value field the app KYC form and
    /// the dashboard walk-in KYC set. Defaults to ride-only when omitted.
    service_types: Option<Vec<String>>,
}

async fn add_driver(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
    Json(body): Json<AddDriver>,
) -> AppResult<Json<serde_json::Value>> {
    let my_role = member_role(&st.db, claims.sub, pid).await?;
    if !can_manage_drivers(&my_role) {
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
    if let Some(c) = &body.vehicle_class
        && !matches!(c.as_str(), "two_wheeler" | "three_wheeler" | "four_wheeler")
    {
        return Err(AppError::BadRequest(
            "vehicle_class must be 'two_wheeler', 'three_wheeler' or 'four_wheeler'".into(),
        ));
    }
    let plate = body.plate_number.as_deref().unwrap_or("").trim();
    if plate.is_empty() {
        return Err(AppError::BadRequest("plate_number is required".into()));
    }
    if body.model.as_deref().unwrap_or("").trim().is_empty() {
        return Err(AppError::BadRequest("vehicle model is required".into()));
    }
    let vehicle_class = body
        .vehicle_class
        .as_deref()
        .ok_or_else(|| AppError::BadRequest("vehicle_class is required".into()))?;
    let service_types = validate_driver_service_types(body.service_types)?;

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

    // Ensure a driver profile exists (KYC starts pending; staff approve later).
    let driver_id: Uuid = sqlx::query_scalar(
        "INSERT INTO drivers (user_id, license_number, address, kyc_status, service_types) \
         VALUES ($1, $2, $3, 'pending', $4) \
         ON CONFLICT (user_id) DO UPDATE SET \
             license_number = COALESCE(EXCLUDED.license_number, drivers.license_number), \
             address = COALESCE(EXCLUDED.address, drivers.address), \
             service_types = EXCLUDED.service_types \
         RETURNING id",
    )
    .bind(user_id)
    .bind(body.license_number)
    .bind(body.address)
    .bind(&service_types)
    .fetch_one(&mut *tx)
    .await?;

    // Vehicle capture.
    sqlx::query(
        "INSERT INTO vehicles (driver_id, class, plate_number, model) VALUES ($1, $2::vehicle_class, $3, $4)",
    )
    .bind(driver_id)
    .bind(vehicle_class)
    .bind(plate)
    .bind(body.model.as_deref().map(str::trim))
    .execute(&mut *tx)
    .await?;

    // Link to the fleet (one active fleet per driver).
    let linked = sqlx::query(
        "INSERT INTO partner_drivers (partner_id, driver_user_id, invited_by) VALUES ($1, $2, $3)",
    )
    .bind(pid)
    .bind(user_id)
    .bind(claims.sub)
    .execute(&mut *tx)
    .await;
    if let Err(sqlx::Error::Database(db)) = &linked
        && db.is_unique_violation()
    {
        return Err(AppError::conflict(
            ErrorCode::DriverAlreadyInFleet,
            "this driver is already active in a fleet",
        ));
    }
    linked?;

    audit::partner(&mut tx, claims.sub, pid, "partner.driver.add", user_id).await?;
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
    let my_role = member_role(&st.db, claims.sub, pid).await?;
    if !can_manage_drivers(&my_role) {
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
    monthly_cap: Option<Decimal>,
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
    monthly_cap: Option<Decimal>,
}

async fn add_rider(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
    Json(body): Json<AddRider>,
) -> AppResult<Json<serde_json::Value>> {
    let my_role = member_role(&st.db, claims.sub, pid).await?;
    if !can_manage_drivers(&my_role) {
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
    if let Err(sqlx::Error::Database(db)) = &linked
        && db.is_unique_violation()
    {
        return Err(AppError::conflict(
            ErrorCode::Conflict,
            "this rider is already on a corporate tab",
        ));
    }
    linked?;
    audit::partner(&mut tx, claims.sub, pid, "partner.rider.add", user_id).await?;
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
    let my_role = member_role(&st.db, claims.sub, pid).await?;
    if !can_manage_drivers(&my_role) {
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
    .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(Json(json!({ "ok": true, "status": body.status })))
}
