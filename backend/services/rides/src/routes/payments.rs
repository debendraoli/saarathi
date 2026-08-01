//! Payment endpoints: rider credit top-up (+ confirm webhook), balance, and
//! driver payouts/withdrawals. Customer pays the platform; the platform settles.

use crate::auth::{AuthUser, StaffUser};
use crate::error::{AppError, AppResult};
use crate::payments;
use crate::state::AppState;
use axum::extract::State;
use axum::{
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use saarathi_core::api::ErrorCode;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/credits", get(balance))
        .route("/v1/credits/topup", post(topup))
        .route("/v1/credits/topup/confirm", post(confirm_topup))
        .route("/v1/payouts", get(list_payouts).post(request_payout))
        .route("/v1/admin/payouts", get(admin_payouts))
}

#[derive(Serialize, sqlx::FromRow)]
struct CreditTxn {
    txn_type: String,
    amount: Decimal,
    balance_after: Option<Decimal>,
    reference: Option<String>,
    created_at: DateTime<Utc>,
}

async fn balance(State(st): State<AppState>, AuthUser(claims): AuthUser) -> AppResult<Json<Value>> {
    let bal = payments::rider_balance(&st.db, claims.sub).await?;
    let txns: Vec<CreditTxn> = sqlx::query_as(
        "SELECT txn_type, amount, balance_after, reference, created_at \
         FROM credit_transactions WHERE user_id = $1 AND kind = 'rider' \
         ORDER BY created_at DESC LIMIT 50",
    )
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(
        json!({ "balance": bal, "currency": "NPR", "transactions": txns }),
    ))
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
    if body.amount <= Decimal::ZERO {
        return Err(AppError::bad(
            ErrorCode::AmountInvalid,
            "amount must be positive",
        ));
    }
    let reference = st.payments.start_topup(claims.sub, body.amount);
    sqlx::query(
        "INSERT INTO topup_intents (reference, user_id, amount, provider) VALUES ($1, $2, $3, $4)",
    )
    .bind(&reference)
    .bind(claims.sub)
    .bind(body.amount)
    .bind(st.payments.name())
    .execute(&st.db)
    .await?;
    // A real PSP returns a checkout URL/deeplink here.
    Ok(Json(json!({
        "reference": reference,
        "amount": body.amount,
        "provider": st.payments.name(),
        "checkout_url": format!("mock://pay/{reference}"),
    })))
}

#[derive(Deserialize)]
struct ConfirmRequest {
    reference: String,
}

/// Simulates the PSP webhook/callback confirming a top-up. Idempotent.
/// (Production: verify the provider's signature before crediting.)
async fn confirm_topup(
    State(st): State<AppState>,
    Json(body): Json<ConfirmRequest>,
) -> AppResult<Json<Value>> {
    let mut tx = st.db.begin().await?;
    let intent: Option<(Uuid, Decimal, String, String)> = sqlx::query_as(
        "SELECT user_id, amount, status, kind FROM topup_intents WHERE reference = $1 FOR UPDATE",
    )
    .bind(&body.reference)
    .fetch_optional(&mut *tx)
    .await?;
    let (user_id, amount, status, kind) = intent.ok_or(AppError::NotFound)?;

    if status == "confirmed" {
        return Ok(Json(json!({ "confirmed": true, "idempotent": true })));
    }

    // Credit the right account (rider prepaid balance or driver credit balance).
    let balance = if kind == "driver" {
        payments::credit_driver(&mut tx, user_id, amount, "topup", Some(&body.reference)).await?
    } else {
        payments::credit_rider(
            &mut tx,
            user_id,
            amount,
            "topup",
            Some(&body.reference),
            None,
        )
        .await?
    };
    sqlx::query(
        "UPDATE topup_intents SET status = 'confirmed', confirmed_at = now() WHERE reference = $1",
    )
    .bind(&body.reference)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    Ok(Json(json!({ "confirmed": true, "balance": balance })))
}

#[derive(Deserialize)]
struct PayoutRequest {
    /// Amount to withdraw; omitted = whole positive balance.
    amount: Option<Decimal>,
}

async fn request_payout(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<PayoutRequest>,
) -> AppResult<Json<Value>> {
    if claims.role != "driver" {
        return Err(AppError::Forbidden);
    }
    let mut tx = st.db.begin().await?;

    let wallet: Option<(Decimal,)> =
        sqlx::query_as("SELECT balance FROM driver_wallets WHERE driver_id = $1 FOR UPDATE")
            .bind(claims.sub)
            .fetch_optional(&mut *tx)
            .await?;
    let available = wallet.map(|w| w.0).unwrap_or(Decimal::ZERO);
    let amount = body.amount.unwrap_or(available);

    if amount <= Decimal::ZERO || amount > available {
        return Err(AppError::BadRequest(
            "amount exceeds available balance".into(),
        ));
    }

    let reference = st.payments.start_payout(claims.sub, amount);
    let (new_balance,): (Decimal,) = sqlx::query_as(
        "UPDATE driver_wallets SET balance = balance - $2, updated_at = now() \
         WHERE driver_id = $1 RETURNING balance",
    )
    .bind(claims.sub)
    .bind(amount)
    .fetch_one(&mut *tx)
    .await?;

    // Mock provider settles instantly; a real PSP would go 'processing' → webhook 'paid'.
    sqlx::query(
        "INSERT INTO payout_requests (driver_id, amount, status, reference, processed_at) \
         VALUES ($1, $2, 'paid', $3, now())",
    )
    .bind(claims.sub)
    .bind(amount)
    .bind(&reference)
    .execute(&mut *tx)
    .await?;
    payments::log_driver_payout(&mut tx, claims.sub, amount, new_balance, &reference).await?;

    tx.commit().await?;
    Ok(Json(
        json!({ "amount": amount, "reference": reference, "balance": new_balance }),
    ))
}

#[derive(Serialize, sqlx::FromRow)]
struct Payout {
    id: Uuid,
    driver_id: Uuid,
    amount: Decimal,
    status: String,
    reference: Option<String>,
    created_at: DateTime<Utc>,
}

async fn list_payouts(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Vec<Payout>>> {
    let rows: Vec<Payout> = sqlx::query_as(
        "SELECT id, driver_id, amount, status, reference, created_at \
         FROM payout_requests WHERE driver_id = $1 ORDER BY created_at DESC LIMIT 100",
    )
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

async fn admin_payouts(
    State(st): State<AppState>,
    _staff: StaffUser,
) -> AppResult<Json<Vec<Payout>>> {
    let rows: Vec<Payout> = sqlx::query_as(
        "SELECT id, driver_id, amount, status, reference, created_at \
         FROM payout_requests ORDER BY created_at DESC LIMIT 200",
    )
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}
