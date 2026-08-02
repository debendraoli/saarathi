//! Payments & wallet accounting (E3) — the **settlement** helpers used inside
//! the atomic trip transaction (and driver subscription/credit flows). Standalone
//! payment *operations* (top-ups, payouts, PSP callbacks) live in the separate
//! `saarathi-payments` service. The `PaymentProvider` hand-off is shared via
//! `saarathi_core::payments`.

use crate::error::{AppError, AppResult};
use rust_decimal::Decimal;
use saarathi_core::api::ErrorCode;
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

/// Debit a rider's prepaid balance for a ride payment. Fails if insufficient.
pub async fn debit_rider(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    amount: Decimal,
    txn_type: &str,
    trip_id: Option<Uuid>,
) -> AppResult<Decimal> {
    let current: Option<(Decimal,)> = sqlx::query_as(
        "SELECT balance FROM credit_accounts WHERE user_id = $1 AND kind = 'rider' FOR UPDATE",
    )
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await?;
    let balance = current.map(|b| b.0).unwrap_or(Decimal::ZERO);
    if balance < amount {
        return Err(AppError::bad(
            ErrorCode::InsufficientCredits,
            "insufficient credits",
        ));
    }
    let (new_balance,): (Decimal,) = sqlx::query_as(
        "UPDATE credit_accounts SET balance = balance - $2, updated_at = now() \
         WHERE user_id = $1 AND kind = 'rider' RETURNING balance",
    )
    .bind(user_id)
    .bind(amount)
    .fetch_one(&mut **tx)
    .await?;

    log_txn(
        tx,
        user_id,
        "rider",
        txn_type,
        -amount,
        new_balance,
        None,
        trip_id,
    )
    .await?;
    Ok(new_balance)
}

#[allow(clippy::too_many_arguments)]
async fn log_txn(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    kind: &str,
    txn_type: &str,
    amount: Decimal,
    balance_after: Decimal,
    reference: Option<&str>,
    trip_id: Option<Uuid>,
) -> AppResult<()> {
    sqlx::query(
        "INSERT INTO credit_transactions (user_id, kind, txn_type, amount, balance_after, reference, trip_id) \
         VALUES ($1, $2, $3, $4, $5, $6, $7)",
    )
    .bind(user_id)
    .bind(kind)
    .bind(txn_type)
    .bind(amount)
    .bind(balance_after)
    .bind(reference)
    .bind(trip_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

/// Current prepaid balance for a rider (read-only).
pub async fn rider_balance(pool: &sqlx::PgPool, user_id: Uuid) -> AppResult<Decimal> {
    let bal: Option<(Decimal,)> =
        sqlx::query_as("SELECT balance FROM credit_accounts WHERE user_id = $1 AND kind = 'rider'")
            .bind(user_id)
            .fetch_optional(pool)
            .await?;
    Ok(bal.map(|b| b.0).unwrap_or(Decimal::ZERO))
}

/// Credit a driver's prepaid credit account (top-up / fair-cap refund).
pub async fn credit_driver(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    amount: Decimal,
    txn_type: &str,
    reference: Option<&str>,
) -> AppResult<Decimal> {
    let (balance,): (Decimal,) = sqlx::query_as(
        "INSERT INTO credit_accounts (user_id, kind, balance, updated_at) \
         VALUES ($1, 'driver', $2, now()) \
         ON CONFLICT (user_id, kind) DO UPDATE SET balance = credit_accounts.balance + $2, updated_at = now() \
         RETURNING balance",
    )
    .bind(user_id)
    .bind(amount)
    .fetch_one(&mut **tx)
    .await?;
    log_txn(
        tx, user_id, "driver", txn_type, amount, balance, reference, None,
    )
    .await?;
    Ok(balance)
}

/// Debit a driver's prepaid credits (e.g. buying a subscription). Fails if short.
pub async fn debit_driver(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    amount: Decimal,
    txn_type: &str,
) -> AppResult<Decimal> {
    let current: Option<(Decimal,)> = sqlx::query_as(
        "SELECT balance FROM credit_accounts WHERE user_id = $1 AND kind = 'driver' FOR UPDATE",
    )
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await?;
    let balance = current.map(|b| b.0).unwrap_or(Decimal::ZERO);
    if balance < amount {
        return Err(AppError::bad(
            ErrorCode::InsufficientDriverCredits,
            "insufficient driver credits",
        ));
    }
    let (new_balance,): (Decimal,) = sqlx::query_as(
        "UPDATE credit_accounts SET balance = balance - $2, updated_at = now() \
         WHERE user_id = $1 AND kind = 'driver' RETURNING balance",
    )
    .bind(user_id)
    .bind(amount)
    .fetch_one(&mut **tx)
    .await?;
    log_txn(
        tx,
        user_id,
        "driver",
        txn_type,
        -amount,
        new_balance,
        None,
        None,
    )
    .await?;
    Ok(new_balance)
}

/// Credit a driver's earnings wallet (withdrawable). Used for platform-funded
/// driver incentives / campaign bonuses. Returns the new wallet balance.
pub async fn credit_driver_wallet(
    tx: &mut Transaction<'_, Postgres>,
    driver_id: Uuid,
    amount: Decimal,
    reference: &str,
) -> AppResult<Decimal> {
    let (balance,): (Decimal,) = sqlx::query_as(
        "INSERT INTO driver_wallets (driver_id, balance, updated_at) VALUES ($1, $2, now()) \
         ON CONFLICT (driver_id) DO UPDATE SET balance = driver_wallets.balance + $2, updated_at = now() \
         RETURNING balance",
    )
    .bind(driver_id)
    .bind(amount)
    .fetch_one(&mut **tx)
    .await?;
    log_txn(
        tx,
        driver_id,
        "driver",
        "bonus",
        amount,
        balance,
        Some(reference),
        None,
    )
    .await?;
    Ok(balance)
}

pub async fn driver_credit_balance(pool: &sqlx::PgPool, user_id: Uuid) -> AppResult<Decimal> {
    let bal: Option<(Decimal,)> = sqlx::query_as(
        "SELECT balance FROM credit_accounts WHERE user_id = $1 AND kind = 'driver'",
    )
    .bind(user_id)
    .fetch_optional(pool)
    .await?;
    Ok(bal.map(|b| b.0).unwrap_or(Decimal::ZERO))
}

/// Is there a currently-active subscription pass for this driver?
pub async fn has_active_pass(
    tx: &mut Transaction<'_, Postgres>,
    driver_id: Uuid,
) -> AppResult<bool> {
    let row: Option<(Uuid,)> = sqlx::query_as(
        "SELECT id FROM subscription_passes WHERE driver_id = $1 AND status = 'active' AND ends_at > now() LIMIT 1",
    )
    .bind(driver_id)
    .fetch_optional(&mut **tx)
    .await?;
    Ok(row.is_some())
}
