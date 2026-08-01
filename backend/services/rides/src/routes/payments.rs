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
        .route("/v1/psp/payout/callback", post(payout_callback))
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

    // Withhold TDS; the driver nets `net`, the platform remits `tds` to the IRD.
    let tds = (amount * st.config.tds_rate).round_dp(2);
    let net = amount - tds;
    // Real-PSP lifecycle: the payout starts 'processing' and is settled (or
    // reversed) by the provider's signed callback — see `payout_callback`.
    sqlx::query(
        "INSERT INTO payout_requests (driver_id, amount, tds_amount, net_amount, status, reference) \
         VALUES ($1, $2, $3, $4, 'processing', $5)",
    )
    .bind(claims.sub)
    .bind(amount)
    .bind(tds)
    .bind(net)
    .bind(&reference)
    .execute(&mut *tx)
    .await?;
    payments::log_driver_payout(&mut tx, claims.sub, amount, new_balance, &reference).await?;

    tx.commit().await?;
    Ok(Json(json!({
        "amount": amount,
        "tds": tds,
        "net": net,
        "reference": reference,
        "status": "processing",
        "balance": new_balance,
    })))
}

#[derive(Deserialize)]
struct PayoutCallback {
    reference: String,
    /// 'paid' settles it; anything else fails it and reverses the wallet debit.
    outcome: String,
}

/// PSP payout webhook (mock). In production, verify the provider's signature
/// before trusting this. Settles a driver **or** partner payout by reference; on
/// failure it reverses the wallet debit so no money is lost.
async fn payout_callback(
    State(st): State<AppState>,
    Json(body): Json<PayoutCallback>,
) -> AppResult<Json<Value>> {
    let paid = body.outcome == "paid";
    let mut tx = st.db.begin().await?;

    // Driver payout?
    let driver: Option<(Uuid, Decimal, String)> = sqlx::query_as(
        "SELECT driver_id, amount, status FROM payout_requests WHERE reference = $1 FOR UPDATE",
    )
    .bind(&body.reference)
    .fetch_optional(&mut *tx)
    .await?;
    if let Some((driver_id, amount, status)) = driver {
        if status != "processing" {
            return Ok(Json(json!({ "settled": true, "idempotent": true })));
        }
        if paid {
            sqlx::query("UPDATE payout_requests SET status = 'paid', processed_at = now() WHERE reference = $1")
                .bind(&body.reference)
                .execute(&mut *tx)
                .await?;
        } else {
            sqlx::query("UPDATE payout_requests SET status = 'failed', processed_at = now() WHERE reference = $1")
                .bind(&body.reference)
                .execute(&mut *tx)
                .await?;
            let (bal,): (Decimal,) = sqlx::query_as(
                "UPDATE driver_wallets SET balance = balance + $2, updated_at = now() \
                 WHERE driver_id = $1 RETURNING balance",
            )
            .bind(driver_id)
            .bind(amount)
            .fetch_one(&mut *tx)
            .await?;
            payments::log_driver_refund(&mut tx, driver_id, amount, bal, &body.reference).await?;
        }
        tx.commit().await?;
        return Ok(Json(json!({ "settled": true, "outcome": body.outcome })));
    }

    // Partner payout?
    let partner: Option<(Uuid, Decimal, String)> = sqlx::query_as(
        "SELECT partner_id, amount, status FROM partner_payouts WHERE reference = $1 FOR UPDATE",
    )
    .bind(&body.reference)
    .fetch_optional(&mut *tx)
    .await?;
    if let Some((partner_id, amount, status)) = partner {
        if status != "processing" {
            return Ok(Json(json!({ "settled": true, "idempotent": true })));
        }
        if paid {
            sqlx::query("UPDATE partner_payouts SET status = 'paid', processed_at = now() WHERE reference = $1")
                .bind(&body.reference)
                .execute(&mut *tx)
                .await?;
        } else {
            sqlx::query("UPDATE partner_payouts SET status = 'failed', processed_at = now() WHERE reference = $1")
                .bind(&body.reference)
                .execute(&mut *tx)
                .await?;
            crate::partner_ledger::append(&mut tx, partner_id, None, "payout_reversal", amount)
                .await?;
        }
        tx.commit().await?;
        return Ok(Json(json!({ "settled": true, "outcome": body.outcome })));
    }

    Err(AppError::NotFound)
}

#[derive(Serialize, sqlx::FromRow)]
struct Payout {
    id: Uuid,
    driver_id: Uuid,
    amount: Decimal,
    tds_amount: Decimal,
    net_amount: Option<Decimal>,
    status: String,
    reference: Option<String>,
    created_at: DateTime<Utc>,
}

async fn list_payouts(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Vec<Payout>>> {
    let rows: Vec<Payout> = sqlx::query_as(
        "SELECT id, driver_id, amount, tds_amount, net_amount, status, reference, created_at \
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
        "SELECT id, driver_id, amount, tds_amount, net_amount, status, reference, created_at \
         FROM payout_requests ORDER BY created_at DESC LIMIT 200",
    )
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}
