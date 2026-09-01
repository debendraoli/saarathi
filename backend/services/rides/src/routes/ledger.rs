//! Ledger + driver-wallet read endpoints (staff + driver).

use crate::auth::{AuthUser, StaffUser};
use crate::error::AppResult;
use crate::ledger;
use crate::state::AppState;
use axum::extract::State;
use axum::{Json, Router, routing::get};
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde_json::{Value, json};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/admin/ledger", get(list))
        .route("/v1/admin/ledger/verify", get(verify))
        .route("/v1/wallet", get(my_wallet))
}

#[derive(serde::Serialize, sqlx::FromRow)]
struct LedgerEntry {
    seq: i64,
    trip_id: Uuid,
    driver_id: Option<Uuid>,
    gross: Decimal,
    commission: Decimal,
    accident_fund: Decimal,
    driver_payout: Decimal,
    payment_method: String,
    entry_hash: String,
    report_status: String,
    created_at: DateTime<Utc>,
}

async fn list(State(st): State<AppState>, _staff: StaffUser) -> AppResult<Json<Vec<LedgerEntry>>> {
    let rows: Vec<LedgerEntry> = sqlx::query_as(
        "SELECT seq, trip_id, driver_id, gross, commission, accident_fund, driver_payout, \
                payment_method, entry_hash, report_status, created_at \
         FROM ledger_entries ORDER BY seq DESC LIMIT 200",
    )
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

async fn verify(State(st): State<AppState>, _staff: StaffUser) -> AppResult<Json<Value>> {
    let ok = ledger::verify_chain(&st.db).await?;
    Ok(Json(json!({ "chain_intact": ok })))
}

async fn my_wallet(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Value>> {
    let balance: Option<(Decimal,)> =
        sqlx::query_as("SELECT balance FROM driver_wallets WHERE driver_id = $1")
            .bind(claims.sub)
            .fetch_optional(&st.db)
            .await?;
    Ok(Json(json!({
        "driver_id": claims.sub,
        "balance": balance.map(|b| b.0).unwrap_or(Decimal::ZERO),
        "currency": "NPR",
    })))
}
