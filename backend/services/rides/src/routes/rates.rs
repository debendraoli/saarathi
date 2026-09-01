//! Base per-km rate per vehicle class, dashboard-editable via a maker-checker
//! flow: any staff proposes a new rate, only a super_admin may approve it —
//! same shape as KYC/place-contribution approval elsewhere in the platform,
//! but gated stricter (super_admin, not admin) since a rate change moves
//! every fare quoted on the platform from that point on, not one account.

use crate::auth::{AdminUser, StaffUser};
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{
    Json, Router,
    routing::{get, post},
};
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use saarathi_core::domain::roles;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/admin/rates", get(current))
        .route(
            "/v1/admin/rates/proposals",
            get(list_proposals).post(propose),
        )
        .route("/v1/admin/rates/proposals/{id}/approve", post(approve))
        .route("/v1/admin/rates/proposals/{id}/reject", post(reject))
}

/// The three classes rates apply to — same set `pricing.rs` prices, kept in
/// one place so a typo'd class name can't silently create an orphan row.
const VEHICLE_CLASSES: [&str; 3] = ["two_wheeler", "three_wheeler", "four_wheeler"];

#[derive(Serialize)]
struct CurrentRate {
    vehicle_class: String,
    per_km_rate: Decimal,
    /// True once a dashboard-approved rate exists; false means this class is
    /// still on its `FARE_*_PER_KM` env default (see `pricing.rs`).
    is_override: bool,
}

async fn current(
    State(st): State<AppState>,
    _staff: StaffUser,
) -> AppResult<Json<Vec<CurrentRate>>> {
    let rows: Vec<(String, Decimal)> =
        sqlx::query_as("SELECT vehicle_class, per_km_rate FROM fare_rates")
            .fetch_all(&st.db)
            .await?;
    let out = VEHICLE_CLASSES
        .iter()
        .map(|&vc| {
            if let Some((_, rate)) = rows.iter().find(|(c, _)| c == vc) {
                CurrentRate {
                    vehicle_class: vc.to_string(),
                    per_km_rate: *rate,
                    is_override: true,
                }
            } else {
                CurrentRate {
                    vehicle_class: vc.to_string(),
                    per_km_rate: env_default(&st, vc),
                    is_override: false,
                }
            }
        })
        .collect();
    Ok(Json(out))
}

fn env_default(st: &AppState, vehicle_class: &str) -> Decimal {
    match vehicle_class {
        "two_wheeler" => st.config.two_wheeler_per_km,
        "three_wheeler" => st.config.three_wheeler_per_km,
        _ => st.config.four_wheeler_per_km,
    }
}

#[derive(Serialize, sqlx::FromRow)]
struct Proposal {
    id: Uuid,
    vehicle_class: String,
    per_km_rate: Decimal,
    proposed_by: Uuid,
    status: String,
    rejection_reason: Option<String>,
    reviewed_by: Option<Uuid>,
    reviewed_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
}

async fn list_proposals(
    State(st): State<AppState>,
    _staff: StaffUser,
) -> AppResult<Json<Vec<Proposal>>> {
    let rows: Vec<Proposal> = sqlx::query_as(
        "SELECT id, vehicle_class, per_km_rate, proposed_by, status, rejection_reason, \
                reviewed_by, reviewed_at, created_at \
         FROM fare_rate_proposals ORDER BY created_at DESC LIMIT 100",
    )
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
struct NewProposal {
    vehicle_class: String,
    per_km_rate: Decimal,
}

async fn propose(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Json(body): Json<NewProposal>,
) -> AppResult<Json<Proposal>> {
    if !VEHICLE_CLASSES.contains(&body.vehicle_class.as_str()) {
        return Err(AppError::BadRequest("unknown vehicle_class".into()));
    }
    if body.per_km_rate <= Decimal::ZERO {
        return Err(AppError::BadRequest("per_km_rate must be positive".into()));
    }
    let row: Proposal = sqlx::query_as(
        "INSERT INTO fare_rate_proposals (vehicle_class, per_km_rate, proposed_by) \
         VALUES ($1, $2, $3) \
         RETURNING id, vehicle_class, per_km_rate, proposed_by, status, rejection_reason, \
                   reviewed_by, reviewed_at, created_at",
    )
    .bind(&body.vehicle_class)
    .bind(body.per_km_rate)
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(row))
}

/// `AdminUser` lets admin+super_admin through the door (consistent with
/// every other approval endpoint in this codebase), but a rate change is
/// checked stricter than that in-handler — only super_admin may actually
/// approve one.
fn require_super_admin(claims: &saarathi_core::authn::Claims) -> AppResult<()> {
    if claims.role != roles::SUPER_ADMIN {
        return Err(AppError::Forbidden);
    }
    Ok(())
}

async fn approve(
    State(st): State<AppState>,
    AdminUser(claims): AdminUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Proposal>> {
    require_super_admin(&claims)?;
    let mut tx = st.db.begin().await?;
    let row: Option<Proposal> = sqlx::query_as(
        "UPDATE fare_rate_proposals SET status = 'approved', reviewed_by = $2, reviewed_at = now() \
         WHERE id = $1 AND status = 'pending' \
         RETURNING id, vehicle_class, per_km_rate, proposed_by, status, rejection_reason, \
                   reviewed_by, reviewed_at, created_at",
    )
    .bind(id)
    .bind(claims.sub)
    .fetch_optional(&mut *tx)
    .await?;
    let Some(row) = row else {
        return Err(AppError::NotFound);
    };
    sqlx::query(
        "INSERT INTO fare_rates (vehicle_class, per_km_rate, updated_by, updated_at) \
         VALUES ($1, $2, $3, now()) \
         ON CONFLICT (vehicle_class) DO UPDATE SET \
             per_km_rate = EXCLUDED.per_km_rate, \
             updated_by = EXCLUDED.updated_by, \
             updated_at = now()",
    )
    .bind(&row.vehicle_class)
    .bind(row.per_km_rate)
    .bind(claims.sub)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Json(row))
}

#[derive(Deserialize, Default)]
struct RejectBody {
    reason: Option<String>,
}

async fn reject(
    State(st): State<AppState>,
    AdminUser(claims): AdminUser,
    Path(id): Path<Uuid>,
    body: Option<Json<RejectBody>>,
) -> AppResult<Json<Proposal>> {
    require_super_admin(&claims)?;
    let reason = body.and_then(|b| b.0.reason);
    let row: Option<Proposal> = sqlx::query_as(
        "UPDATE fare_rate_proposals \
         SET status = 'rejected', rejection_reason = $2, reviewed_by = $3, reviewed_at = now() \
         WHERE id = $1 AND status = 'pending' \
         RETURNING id, vehicle_class, per_km_rate, proposed_by, status, rejection_reason, \
                   reviewed_by, reviewed_at, created_at",
    )
    .bind(id)
    .bind(reason)
    .bind(claims.sub)
    .fetch_optional(&st.db)
    .await?;
    row.map(Json).ok_or(AppError::NotFound)
}
