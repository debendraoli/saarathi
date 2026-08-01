//! Partner-scoped fleet analytics. Read-only KPIs for a partner's own fleet.
//! Membership is resolved from the shared DB (`partner_members`) — a caller may
//! only see analytics for a fleet they belong to (hard tenant isolation).

use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{routing::get, Json, Router};
use rust_decimal::Decimal;
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new().route("/v1/partner/{pid}/analytics", get(analytics))
}

/// 403 unless the caller is an active member of the (active) partner.
async fn require_member(st: &AppState, user_id: Uuid, partner_id: Uuid) -> AppResult<()> {
    let ok: Option<(i32,)> = sqlx::query_as(
        "SELECT 1 FROM partner_members pm JOIN partners p ON p.id = pm.partner_id \
         WHERE pm.partner_id = $1 AND pm.user_id = $2 AND pm.status = 'active' AND p.status = 'active'",
    )
    .bind(partner_id)
    .bind(user_id)
    .fetch_optional(&st.db)
    .await?;
    if ok.is_none() {
        return Err(AppError::Forbidden);
    }
    Ok(())
}

#[derive(sqlx::FromRow)]
struct FleetAgg {
    total: i64,
    completed: i64,
    cancelled: i64,
    gmv: Decimal,
    driver_earnings: Decimal,
}

async fn analytics(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
) -> AppResult<Json<Value>> {
    require_member(&st, claims.sub, pid).await?;

    let active_drivers: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM partner_drivers WHERE partner_id = $1 AND status = 'active'",
    )
    .bind(pid)
    .fetch_one(&st.db)
    .await?;

    // Trips flown by drivers currently in this fleet.
    let agg: FleetAgg = sqlx::query_as(
        "SELECT count(*) AS total, \
                count(*) FILTER (WHERE status = 'completed') AS completed, \
                count(*) FILTER (WHERE status = 'cancelled') AS cancelled, \
                coalesce(sum(gross_fare)   FILTER (WHERE status = 'completed'), 0) AS gmv, \
                coalesce(sum(driver_payout) FILTER (WHERE status = 'completed'), 0) AS driver_earnings \
         FROM trips \
         WHERE driver_id IN (SELECT driver_user_id FROM partner_drivers \
                             WHERE partner_id = $1 AND status = 'active')",
    )
    .bind(pid)
    .fetch_one(&st.db)
    .await?;

    // Per-driver leaderboard (top earners in the fleet).
    let leaders: Vec<(Uuid, Option<String>, i64, Decimal)> = sqlx::query_as(
        "SELECT t.driver_id, u.full_name, \
                count(*) FILTER (WHERE t.status = 'completed') AS trips, \
                coalesce(sum(t.driver_payout) FILTER (WHERE t.status = 'completed'), 0) AS earnings \
         FROM trips t JOIN users u ON u.id = t.driver_id \
         WHERE t.driver_id IN (SELECT driver_user_id FROM partner_drivers \
                               WHERE partner_id = $1 AND status = 'active') \
         GROUP BY t.driver_id, u.full_name ORDER BY earnings DESC LIMIT 10",
    )
    .bind(pid)
    .fetch_all(&st.db)
    .await?;

    let leaderboard: Vec<Value> = leaders
        .into_iter()
        .map(|(id, name, trips, earnings)| {
            json!({ "driver_id": id, "name": name, "trips": trips, "earnings": earnings })
        })
        .collect();

    Ok(Json(json!({
        "active_drivers": active_drivers,
        "trips": { "total": agg.total, "completed": agg.completed, "cancelled": agg.cancelled },
        "money": { "gmv": agg.gmv, "driver_earnings": agg.driver_earnings, "currency": "NPR" },
        "leaderboard": leaderboard,
    })))
}
