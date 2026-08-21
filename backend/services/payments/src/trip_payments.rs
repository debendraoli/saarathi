//! Direct gateway payment for a specific trip's fare — e.g. a rider settling
//! a cash-designated ride via Khalti instead of physical cash. Ride
//! completion itself is untouched (`saarathi-rides` `settle::on_completion`
//! already ran and appended the immutable ledger entry); this only credits
//! the driver's wallet with the trip's `driver_payout` share, exactly as a
//! digital payment would have, recorded as its own `credit_transaction`
//! referencing the trip. Same trust rule as top-ups: only
//! `PaymentProvider::verify_topup`'s server-to-server check may be trusted,
//! never the client's own claim.

use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::{routing::post, Json, Router};
use rust_decimal::Decimal;
use saarathi_core::api::ErrorCode;
use saarathi_core::idempotency::{self, Reservation};
use saarathi_core::payments::VerifyOutcome;
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/payments/trips/{id}/initiate", post(initiate))
        .route("/v1/payments/trips/{id}/confirm", post(confirm))
}

#[derive(sqlx::FromRow)]
struct TripForPayment {
    rider_id: Uuid,
    driver_id: Option<Uuid>,
    final_fare: Decimal,
    driver_payout: Decimal,
    payment_method: String,
    status: String,
}

async fn load_trip(st: &AppState, trip_id: Uuid) -> AppResult<TripForPayment> {
    let row: Option<TripForPayment> = sqlx::query_as(
        "SELECT rider_id, driver_id, final_fare, driver_payout, payment_method, status::text AS status \
         FROM trips WHERE id = $1",
    )
    .bind(trip_id)
    .fetch_optional(&st.db)
    .await?;
    row.ok_or(AppError::NotFound)
}

fn idempotency_key(headers: &HeaderMap) -> AppResult<String> {
    headers
        .get("x-idempotency-key")
        .and_then(|v| v.to_str().ok())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .ok_or_else(|| {
            AppError::bad(
                ErrorCode::Validation,
                "X-Idempotency-Key header is required",
            )
        })
}

async fn initiate(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(trip_id): Path<Uuid>,
    headers: HeaderMap,
) -> AppResult<Json<Value>> {
    let key = idempotency_key(&headers)?;
    let trip = load_trip(&st, trip_id).await?;
    if trip.rider_id != claims.sub {
        return Err(AppError::Forbidden);
    }
    if trip.status != "completed" {
        return Err(AppError::bad(
            ErrorCode::Validation,
            "trip is not completed yet",
        ));
    }
    if trip.payment_method != "cash" {
        return Err(AppError::bad(
            ErrorCode::InvalidPaymentMethod,
            "only cash-designated trips can be paid via a gateway afterward",
        ));
    }
    let existing: Option<(String,)> =
        sqlx::query_as("SELECT status FROM trip_gateway_payments WHERE trip_id = $1")
            .bind(trip_id)
            .fetch_optional(&st.db)
            .await?;
    if let Some((status,)) = existing {
        return Err(AppError::conflict(
            ErrorCode::Conflict,
            format!("a gateway payment for this trip already exists (status: {status})"),
        ));
    }

    let mut reserve_tx = st.db.begin().await?;
    let reservation = idempotency::reserve(&mut reserve_tx, &key, claims.sub, "trips.pay").await?;
    reserve_tx.commit().await?;
    if let Reservation::Replay { status: _, body } = reservation {
        return Ok(Json(body));
    }

    let purchase_order_id = trip_id.to_string();
    let init = st
        .payments
        .start_topup(claims.sub, trip.final_fare, &purchase_order_id)
        .await?;

    let mut tx = st.db.begin().await?;
    sqlx::query(
        "INSERT INTO trip_gateway_payments (trip_id, reference, provider, amount) VALUES ($1, $2, $3, $4)",
    )
    .bind(trip_id)
    .bind(&init.reference)
    .bind(st.payments.name())
    .bind(trip.final_fare)
    .execute(&mut *tx)
    .await?;
    let response = json!({
        "trip_id": trip_id,
        "reference": init.reference,
        "amount": trip.final_fare,
        "provider": st.payments.name(),
        "checkout_url": init.checkout_url,
    });
    idempotency::store(&mut tx, &key, claims.sub, "trips.pay", 200, &response).await?;
    tx.commit().await?;
    Ok(Json(response))
}

async fn confirm(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(trip_id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let trip = load_trip(&st, trip_id).await?;
    if trip.rider_id != claims.sub {
        return Err(AppError::Forbidden);
    }
    let payment: Option<(String, String, Decimal)> = sqlx::query_as(
        "SELECT reference, status, amount FROM trip_gateway_payments WHERE trip_id = $1",
    )
    .bind(trip_id)
    .fetch_optional(&st.db)
    .await?;
    let (reference, status, amount) = payment.ok_or(AppError::NotFound)?;
    if status == "confirmed" {
        return Ok(Json(json!({ "confirmed": true, "idempotent": true })));
    }

    match st.payments.verify_topup(&reference, amount).await? {
        VerifyOutcome::Completed => {}
        VerifyOutcome::Pending => {
            return Ok(Json(json!({ "confirmed": false, "status": "pending" })));
        }
        VerifyOutcome::Failed => {
            sqlx::query(
                "UPDATE trip_gateway_payments SET status = 'failed' WHERE trip_id = $1 AND status <> 'confirmed'",
            )
            .bind(trip_id)
            .execute(&st.db)
            .await?;
            return Err(AppError::bad(
                ErrorCode::Validation,
                "payment was not completed",
            ));
        }
    }

    let mut tx = st.db.begin().await?;
    let status_now: Option<(String,)> =
        sqlx::query_as("SELECT status FROM trip_gateway_payments WHERE trip_id = $1 FOR UPDATE")
            .bind(trip_id)
            .fetch_optional(&mut *tx)
            .await?;
    if status_now.map(|s| s.0).as_deref() == Some("confirmed") {
        tx.commit().await?;
        return Ok(Json(json!({ "confirmed": true, "idempotent": true })));
    }

    let Some(driver_id) = trip.driver_id else {
        return Err(AppError::bad(
            ErrorCode::Validation,
            "trip has no driver to pay out",
        ));
    };
    let balance = saarathi_core::wallet::credit_driver_wallet(
        &mut tx,
        driver_id,
        trip.driver_payout,
        &format!("trip-gateway-payment:{trip_id}"),
    )
    .await?;
    sqlx::query(
        "UPDATE trip_gateway_payments SET status = 'confirmed', confirmed_at = now() WHERE trip_id = $1",
    )
    .bind(trip_id)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Json(json!({ "confirmed": true, "driver_wallet_balance": balance })))
}
