//! Driver prepaid credits (doc 13 §4.1). A driver tops up a credit balance;
//! the platform's per-ride cut is drawn from it on every cash trip instead of
//! the old cash-owed-on-wallet reconciliation (see `ledger::append`). A driver
//! needs a positive balance to accept new job offers (`dispatch::accept_offer`).
//!
//! The time-boxed "unlimited pass" subscription model (doc 13 §4.2) has been
//! retired — see `docs/research/13-revenue-and-monetization.md` — in favour of
//! this always-on per-ride draw, which needs no fair-cap reconciliation because
//! it never charges more than the standard commission.

use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::payments;
use crate::state::AppState;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::{Json, Router, routing::get};
use rust_decimal::Decimal;
use saarathi_core::api::ErrorCode;
use saarathi_core::domain::roles;
use saarathi_core::idempotency::{self, Reservation};
use serde::Deserialize;
use serde_json::{Value, json};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/driver/credits", get(credits))
        .route("/v1/driver/credits/topup", axum::routing::post(topup))
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
    headers: HeaderMap,
    Json(body): Json<TopupRequest>,
) -> AppResult<Json<Value>> {
    if claims.role != roles::DRIVER {
        return Err(AppError::Forbidden);
    }
    let key = saarathi_core::idempotency::key_from_headers(&headers).ok_or_else(|| {
        AppError::bad(
            ErrorCode::Validation,
            "X-Idempotency-Key header is required",
        )
    })?;
    if body.amount <= Decimal::ZERO {
        return Err(AppError::bad(
            ErrorCode::AmountInvalid,
            "amount must be positive",
        ));
    }

    // Claim the idempotency key first (fast, DB-only); the actual initiate
    // call is a slow network round-trip and shouldn't hold a transaction open.
    let mut reserve_tx = st.db.begin().await?;
    let reservation =
        idempotency::reserve(&mut reserve_tx, &key, claims.sub, "driver.credits.topup").await?;
    reserve_tx.commit().await?;
    if let Reservation::Replay { status: _, body } = reservation {
        return Ok(Json(body));
    }

    let purchase_order_id = uuid::Uuid::new_v4().to_string();
    let init = st
        .payments
        .start_topup(claims.sub, body.amount, &purchase_order_id)
        .await?;

    let mut tx = st.db.begin().await?;
    sqlx::query(
        "INSERT INTO topup_intents (reference, user_id, amount, provider, kind) VALUES ($1, $2, $3, $4, 'driver')",
    )
    .bind(&init.reference)
    .bind(claims.sub)
    .bind(body.amount)
    .bind(st.payments.name())
    .execute(&mut *tx)
    .await?;
    let response = json!({
        "reference": init.reference,
        "amount": body.amount,
        "checkout_url": init.checkout_url,
    });
    idempotency::store(
        &mut tx,
        &key,
        claims.sub,
        "driver.credits.topup",
        200,
        &response,
    )
    .await?;
    tx.commit().await?;
    Ok(Json(response))
}
