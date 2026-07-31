//! Driver credits + subscription passes (doc 13). A driver tops up prepaid
//! credits and can buy an "unlimited" pass; while it's active they pay **0%
//! commission** (keep 100% of fares, minus the legal 1% fund). The fair-cap
//! reconciliation refunds any driver who paid more than the 10% cap over a pass.

use crate::auth::{AuthUser, StaffUser};
use crate::error::{AppError, AppResult};
use crate::payments;
use crate::state::AppState;
use axum::extract::State;
use axum::{
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Duration, Utc};
use rust_decimal::{prelude::FromPrimitive, Decimal};
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/driver/credits", get(credits))
        .route("/v1/driver/credits/topup", post(topup))
        .route("/v1/driver/subscription", get(get_pass).post(buy_pass))
        .route("/v1/admin/subscriptions/reconcile", post(reconcile))
}

async fn credits(State(st): State<AppState>, AuthUser(claims): AuthUser) -> AppResult<Json<Value>> {
    let bal = payments::driver_credit_balance(&st.db, claims.sub).await?;
    Ok(Json(json!({ "balance": bal, "currency": "NPR" })))
}

#[derive(Deserialize)]
struct TopupRequest {
    amount: Decimal,
}

async fn topup(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<TopupRequest>,
) -> AppResult<Json<Value>> {
    if claims.role != "driver" {
        return Err(AppError::Forbidden);
    }
    if body.amount <= Decimal::ZERO {
        return Err(AppError::BadRequest("amount must be positive".into()));
    }
    let reference = st.payments.start_topup(claims.sub, body.amount);
    sqlx::query(
        "INSERT INTO topup_intents (reference, user_id, amount, provider, kind) VALUES ($1, $2, $3, $4, 'driver')",
    )
    .bind(&reference)
    .bind(claims.sub)
    .bind(body.amount)
    .bind(st.payments.name())
    .execute(&st.db)
    .await?;
    Ok(Json(json!({
        "reference": reference,
        "amount": body.amount,
        "checkout_url": format!("mock://pay/{reference}"),
    })))
}

async fn get_pass(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Value>> {
    let row: Option<(Uuid, String, DateTime<Utc>)> = sqlx::query_as(
        "SELECT id, plan, ends_at FROM subscription_passes \
         WHERE driver_id = $1 AND status = 'active' AND ends_at > now() ORDER BY ends_at DESC LIMIT 1",
    )
    .bind(claims.sub)
    .fetch_optional(&st.db)
    .await?;
    Ok(Json(match row {
        Some((id, plan, ends_at)) => {
            json!({ "active": true, "id": id, "plan": plan, "ends_at": ends_at })
        }
        None => json!({ "active": false }),
    }))
}

/// Buy the weekly pass, paid from the driver's prepaid credits.
async fn buy_pass(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Value>> {
    if claims.role != "driver" {
        return Err(AppError::Forbidden);
    }
    let price = st.config.subscription_weekly_price;
    let ends_at = Utc::now() + Duration::days(st.config.subscription_weekly_days);

    let mut tx = st.db.begin().await?;
    payments::debit_driver(&mut tx, claims.sub, price, "subscription").await?;
    let (id,): (Uuid,) = sqlx::query_as(
        "INSERT INTO subscription_passes (driver_id, plan, price, ends_at) \
         VALUES ($1, 'weekly', $2, $3) RETURNING id",
    )
    .bind(claims.sub)
    .bind(price)
    .bind(ends_at)
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;

    Ok(Json(
        json!({ "id": id, "plan": "weekly", "price": price, "ends_at": ends_at }),
    ))
}

/// Fair-cap: for each expired pass, if the driver paid more than 10% of the
/// gross fares they earned during it, refund the surplus to their credits.
async fn reconcile(State(st): State<AppState>, _staff: StaffUser) -> AppResult<Json<Value>> {
    let passes: Vec<ExpiredPass> = sqlx::query_as(
        "SELECT id, driver_id, price, starts_at, ends_at FROM subscription_passes \
         WHERE status = 'active' AND ends_at <= now()",
    )
    .fetch_all(&st.db)
    .await?;

    let cap_rate = Decimal::from_f64(0.10).unwrap();
    let mut refunded = 0i64;
    for p in passes {
        let mut tx = st.db.begin().await?;
        let (gross,): (Decimal,) = sqlx::query_as(
            "SELECT COALESCE(SUM(gross), 0) FROM ledger_entries \
             WHERE driver_id = $1 AND created_at >= $2 AND created_at <= $3",
        )
        .bind(p.driver_id)
        .bind(p.starts_at)
        .bind(p.ends_at)
        .fetch_one(&mut *tx)
        .await?;

        let fair = (gross * cap_rate).round_dp(2);
        let refund = if p.price > fair {
            p.price - fair
        } else {
            Decimal::ZERO
        };
        if refund > Decimal::ZERO {
            payments::credit_driver(&mut tx, p.driver_id, refund, "refund", Some("fair-cap"))
                .await?;
            refunded += 1;
        }
        sqlx::query(
            "UPDATE subscription_passes SET status = 'reconciled', fair_cap_refund = $2 WHERE id = $1",
        )
        .bind(p.id)
        .bind(refund)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
    }
    Ok(Json(json!({ "reconciled_passes_with_refund": refunded })))
}

#[derive(sqlx::FromRow)]
struct ExpiredPass {
    id: Uuid,
    driver_id: Uuid,
    price: Decimal,
    starts_at: DateTime<Utc>,
    ends_at: DateTime<Utc>,
}
