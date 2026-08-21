//! Payment operations (standalone transactions — no trip tx): rider credit
//! top-up (+ confirm webhook), balance, and driver payouts/withdrawals + the PSP
//! payout callback. Trip-completion settlement stays in `rides` (atomic).

use crate::auth::{AuthUser, StaffUser};
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use crate::wallet;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::{
    routing::{get, post},
    Json, Router,
};
use chrono::{Datelike, DateTime, Duration, FixedOffset, TimeZone, Utc};
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use saarathi_core::api::ErrorCode;
use saarathi_core::domain::roles;
use saarathi_core::idempotency::{self, Reservation};
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

/// Nepal Time is UTC+5:45 (matches the NPT convention used in saarathi-rides).
const NPT_OFFSET_SECS: i32 = 5 * 3600 + 45 * 60;

/// Required on every money-moving client request (top-up, withdrawal) so a
/// network retry can't double-process. PSP-initiated webhooks are exempt —
/// they're idempotent by their own reference/status check instead.
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

/// Start (Sunday 00:00 NPT, as a UTC instant) of the Nepal calendar week
/// containing `now`.
fn npt_week_start(now: DateTime<Utc>) -> DateTime<Utc> {
    let tz = FixedOffset::east_opt(NPT_OFFSET_SECS).expect("valid offset");
    let local = tz.from_utc_datetime(&now.naive_utc());
    let midnight = local
        .date_naive()
        .and_hms_opt(0, 0, 0)
        .expect("valid time");
    let days_since_sunday = local.weekday().num_days_from_sunday() as i64;
    let week_start_local = tz
        .from_local_datetime(&(midnight - Duration::days(days_since_sunday)))
        .single()
        .expect("unambiguous — fixed offset has no DST");
    week_start_local.with_timezone(&Utc)
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
    let bal = wallet::rider_balance(&st.db, claims.sub).await?;
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
    headers: HeaderMap,
    Json(body): Json<TopupRequest>,
) -> AppResult<Json<Value>> {
    let key = idempotency_key(&headers)?;
    if body.amount <= Decimal::ZERO {
        return Err(AppError::bad(
            ErrorCode::AmountInvalid,
            "amount must be positive",
        ));
    }

    // Claim the idempotency key first (fast, DB-only) so a retry never starts
    // a second provider session — the actual initiate call is a slow network
    // round-trip and shouldn't happen while holding a transaction open.
    let mut reserve_tx = st.db.begin().await?;
    let reservation =
        idempotency::reserve(&mut reserve_tx, &key, claims.sub, "credits.topup").await?;
    reserve_tx.commit().await?;
    if let Reservation::Replay { status: _, body } = reservation {
        return Ok(Json(body));
    }

    let purchase_order_id = Uuid::new_v4().to_string();
    let init = st
        .payments
        .start_topup(claims.sub, body.amount, &purchase_order_id)
        .await?;

    let mut tx = st.db.begin().await?;
    sqlx::query(
        "INSERT INTO topup_intents (reference, user_id, amount, provider) VALUES ($1, $2, $3, $4)",
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
        "provider": st.payments.name(),
        "checkout_url": init.checkout_url,
    });
    idempotency::store(&mut tx, &key, claims.sub, "credits.topup", 200, &response).await?;
    tx.commit().await?;
    Ok(Json(response))
}

#[derive(Deserialize)]
struct ConfirmRequest {
    reference: String,
}

/// Confirms a top-up. The client (app) calls this after the provider's
/// checkout redirect — but the client's claim is never trusted directly: this
/// always re-verifies server-to-server via `PaymentProvider::verify_topup`
/// (Khalti has no signed webhook, so its Lookup API *is* the trust boundary)
/// before crediting anything. Idempotent via `topup_intents.status`.
async fn confirm_topup(
    State(st): State<AppState>,
    Json(body): Json<ConfirmRequest>,
) -> AppResult<Json<Value>> {
    let intent: Option<(Uuid, Decimal, String, String)> = sqlx::query_as(
        "SELECT user_id, amount, status, kind FROM topup_intents WHERE reference = $1",
    )
    .bind(&body.reference)
    .fetch_optional(&st.db)
    .await?;
    let (user_id, amount, status, kind) = intent.ok_or(AppError::NotFound)?;
    if status == "confirmed" {
        return Ok(Json(json!({ "confirmed": true, "idempotent": true })));
    }

    use saarathi_core::payments::VerifyOutcome;
    match st.payments.verify_topup(&body.reference, amount).await? {
        VerifyOutcome::Completed => {}
        VerifyOutcome::Pending => {
            return Ok(Json(json!({ "confirmed": false, "status": "pending" })));
        }
        VerifyOutcome::Failed => {
            sqlx::query(
                "UPDATE topup_intents SET status = 'failed' WHERE reference = $1 AND status <> 'confirmed'",
            )
            .bind(&body.reference)
            .execute(&st.db)
            .await?;
            return Err(AppError::bad(
                ErrorCode::Validation,
                "payment was not completed",
            ));
        }
    }

    let mut tx = st.db.begin().await?;
    // Re-check under a row lock in case of a concurrent confirm racing us.
    let status_now: Option<(String,)> =
        sqlx::query_as("SELECT status FROM topup_intents WHERE reference = $1 FOR UPDATE")
            .bind(&body.reference)
            .fetch_optional(&mut *tx)
            .await?;
    if status_now.map(|s| s.0).as_deref() == Some("confirmed") {
        tx.commit().await?;
        return Ok(Json(json!({ "confirmed": true, "idempotent": true })));
    }

    let balance = if kind == roles::DRIVER {
        wallet::credit_driver(&mut tx, user_id, amount, "topup", Some(&body.reference)).await?
    } else {
        wallet::credit_rider(
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

/// Minimum withdrawal (NPR). Below this a payout isn't worth the PSP fee.
const MIN_WITHDRAWAL: Decimal = dec!(1000);
/// Fee on the 2nd+ withdrawal within the same Nepal calendar week (1 free).
const WEEKLY_FEE_RATE: Decimal = dec!(0.02);

#[derive(Deserialize)]
struct PayoutRequest {
    /// Amount to withdraw; omitted = whole positive balance.
    amount: Option<Decimal>,
    /// Saved payout destination; omitted = the user's default account.
    payout_account_id: Option<Uuid>,
}

async fn request_payout(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    headers: HeaderMap,
    Json(body): Json<PayoutRequest>,
) -> AppResult<Json<Value>> {
    if claims.role != roles::DRIVER {
        return Err(AppError::Forbidden);
    }
    let key = idempotency_key(&headers)?;
    let mut tx = st.db.begin().await?;
    if let Reservation::Replay { status: _, body } =
        idempotency::reserve(&mut tx, &key, claims.sub, "payouts.request").await?
    {
        tx.commit().await?;
        return Ok(Json(body));
    }

    let wallet_row: Option<(Decimal,)> =
        sqlx::query_as("SELECT balance FROM driver_wallets WHERE driver_id = $1 FOR UPDATE")
            .bind(claims.sub)
            .fetch_optional(&mut *tx)
            .await?;
    let available = wallet_row.map(|w| w.0).unwrap_or(Decimal::ZERO);
    let amount = body.amount.unwrap_or(available);

    if amount <= Decimal::ZERO || amount > available {
        return Err(AppError::BadRequest(
            "amount exceeds available balance".into(),
        ));
    }
    if amount < MIN_WITHDRAWAL {
        return Err(AppError::bad(
            ErrorCode::AmountInvalid,
            format!("minimum withdrawal is NPR {MIN_WITHDRAWAL}"),
        ));
    }

    let payout_account_id = match body.payout_account_id {
        Some(id) => {
            let owned: Option<(Uuid,)> =
                sqlx::query_as("SELECT id FROM payout_accounts WHERE id = $1 AND user_id = $2")
                    .bind(id)
                    .bind(claims.sub)
                    .fetch_optional(&mut *tx)
                    .await?;
            Some(owned.ok_or(AppError::NotFound)?.0)
        }
        None => {
            let default: Option<(Uuid,)> = sqlx::query_as(
                "SELECT id FROM payout_accounts WHERE user_id = $1 AND is_default",
            )
            .bind(claims.sub)
            .fetch_optional(&mut *tx)
            .await?;
            default.map(|d| d.0)
        }
    };

    // Weekly fee: 1 free withdrawal per Nepal calendar week (Sun–Sat), 2% after.
    let week_start = npt_week_start(Utc::now());
    let (prior_this_week,): (i64,) = sqlx::query_as(
        "SELECT count(*) FROM payout_requests \
         WHERE driver_id = $1 AND created_at >= $2 AND status <> 'failed'",
    )
    .bind(claims.sub)
    .bind(week_start)
    .fetch_one(&mut *tx)
    .await?;
    let weekly_fee = if prior_this_week > 0 {
        (amount * WEEKLY_FEE_RATE).round_dp(2)
    } else {
        Decimal::ZERO
    };

    let reference = st.payments.start_payout(claims.sub, amount);
    let (new_balance,): (Decimal,) = sqlx::query_as(
        "UPDATE driver_wallets SET balance = balance - $2, updated_at = now() \
         WHERE driver_id = $1 RETURNING balance",
    )
    .bind(claims.sub)
    .bind(amount)
    .fetch_one(&mut *tx)
    .await?;

    let tds = (amount * st.tds_rate).round_dp(2);
    let net = amount - tds - weekly_fee;
    sqlx::query(
        "INSERT INTO payout_requests \
         (driver_id, amount, tds_amount, net_amount, weekly_fee, payout_account_id, status, reference) \
         VALUES ($1, $2, $3, $4, $5, $6, 'processing', $7)",
    )
    .bind(claims.sub)
    .bind(amount)
    .bind(tds)
    .bind(net)
    .bind(weekly_fee)
    .bind(payout_account_id)
    .bind(&reference)
    .execute(&mut *tx)
    .await?;
    wallet::log_driver_payout(&mut tx, claims.sub, amount, new_balance, &reference).await?;

    let response = json!({
        "amount": amount,
        "tds": tds,
        "weekly_fee": weekly_fee,
        "net": net,
        "reference": reference,
        "status": "processing",
        "balance": new_balance,
        "payout_account_id": payout_account_id,
    });
    idempotency::store(&mut tx, &key, claims.sub, "payouts.request", 200, &response).await?;
    tx.commit().await?;
    Ok(Json(response))
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
            wallet::log_driver_refund(&mut tx, driver_id, amount, bal, &body.reference).await?;
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
            wallet::partner_ledger_append(&mut tx, partner_id, None, "payout_reversal", amount)
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

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone, Timelike};

    #[test]
    fn week_start_is_sunday_midnight_npt() {
        // Wed 2026-08-19 10:00 NPT — same week as the pinned Sunday below.
        let wed = Utc.with_ymd_and_hms(2026, 8, 19, 4, 15, 0).unwrap();
        let start = npt_week_start(wed);
        let tz = FixedOffset::east_opt(NPT_OFFSET_SECS).unwrap();
        let local = start.with_timezone(&tz);
        assert_eq!(local.weekday(), chrono::Weekday::Sun);
        assert_eq!((local.hour(), local.minute(), local.second()), (0, 0, 0));
    }

    #[test]
    fn same_week_maps_to_the_same_start() {
        let sun_morning = Utc.with_ymd_and_hms(2026, 8, 16, 1, 0, 0).unwrap();
        let sat_night = Utc.with_ymd_and_hms(2026, 8, 22, 17, 0, 0).unwrap();
        assert_eq!(npt_week_start(sun_morning), npt_week_start(sat_night));
    }

    #[test]
    fn next_week_gets_a_later_start() {
        let this_week = Utc.with_ymd_and_hms(2026, 8, 19, 4, 15, 0).unwrap();
        let next_week = Utc.with_ymd_and_hms(2026, 8, 26, 4, 15, 0).unwrap();
        assert!(npt_week_start(next_week) > npt_week_start(this_week));
        assert_eq!(
            (npt_week_start(next_week) - npt_week_start(this_week)).num_days(),
            7
        );
    }

    #[test]
    fn boundary_just_before_and_after_sunday_midnight_npt() {
        // Sat 23:59:59 NPT is the OLD week; Sun 00:00:00 NPT is the NEW week.
        let sat_2359_npt_as_utc = Utc.with_ymd_and_hms(2026, 8, 15, 18, 14, 59).unwrap();
        let sun_0000_npt_as_utc = Utc.with_ymd_and_hms(2026, 8, 15, 18, 15, 0).unwrap();
        assert_ne!(
            npt_week_start(sat_2359_npt_as_utc),
            npt_week_start(sun_0000_npt_as_utc)
        );
    }
}
