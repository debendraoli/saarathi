//! Driver insights & earnings (E10). Computed on demand from the ledger + wallet
//! + ratings. Cheap for launch scale; move to nightly rollups when volume grows.

use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::extract::State;
use axum::{routing::get, Json, Router};
use rust_decimal::Decimal;
use serde_json::{json, Value};

pub fn routes() -> Router<AppState> {
    Router::new().route("/v1/driver/analytics", get(analytics))
}

#[derive(sqlx::FromRow)]
struct Totals {
    trips_today: i64,
    earnings_today: Decimal,
    trips_7d: i64,
    earnings_7d: Decimal,
    trips_total: i64,
    earnings_total: Decimal,
}

async fn analytics(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Value>> {
    if claims.role != "driver" {
        return Err(AppError::Forbidden);
    }
    let t: Totals = sqlx::query_as(
        "SELECT \
           count(*) FILTER (WHERE created_at::date = current_date) AS trips_today, \
           coalesce(sum(driver_payout) FILTER (WHERE created_at::date = current_date), 0) AS earnings_today, \
           count(*) FILTER (WHERE created_at > now() - interval '7 days') AS trips_7d, \
           coalesce(sum(driver_payout) FILTER (WHERE created_at > now() - interval '7 days'), 0) AS earnings_7d, \
           count(*) AS trips_total, \
           coalesce(sum(driver_payout), 0) AS earnings_total \
         FROM ledger_entries WHERE driver_id = $1",
    )
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await?;

    let wallet: Option<(Decimal,)> =
        sqlx::query_as("SELECT balance FROM driver_wallets WHERE driver_id = $1")
            .bind(claims.sub)
            .fetch_optional(&st.db)
            .await?;

    let rating: (Option<f64>, i64) = sqlx::query_as(
        "SELECT avg(stars)::float8, count(*) FROM ratings WHERE ratee_id = $1 AND role = 'rider_rates_driver'",
    )
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await?;

    Ok(Json(json!({
        "today":  { "trips": t.trips_today, "earnings": t.earnings_today },
        "last_7d": { "trips": t.trips_7d, "earnings": t.earnings_7d },
        "all_time": { "trips": t.trips_total, "earnings": t.earnings_total },
        "wallet_balance": wallet.map(|w| w.0).unwrap_or(Decimal::ZERO),
        "rating": { "avg": rating.0, "count": rating.1 },
        "currency": "NPR",
    })))
}
