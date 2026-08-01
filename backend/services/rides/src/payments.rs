//! Payments & wallet accounting (E3).
//!
//! Customers pay the platform directly (prepaid **credits**); the platform
//! deducts commission + fund via the ledger and pays the driver's net into
//! their wallet, which the driver can **withdraw**. Real PSP integration
//! (eSewa/Khalti/Fonepay/ConnectIPS) drops in behind [`PaymentProvider`]; the
//! `MockProvider` here lets the whole flow run and be tested end-to-end.

use crate::error::{AppError, AppResult};
use rust_decimal::Decimal;
use saarathi_core::api::ErrorCode;
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

/// A payment-service-provider hand-off. Real providers return a checkout URL /
/// token and confirm asynchronously via a signed webhook.
pub trait PaymentProvider: Send + Sync {
    fn name(&self) -> &'static str;
    /// Begin a top-up; returns an opaque reference the client uses to pay.
    fn start_topup(&self, user_id: Uuid, amount: Decimal) -> String;
    /// Begin a payout to a driver; returns a provider reference.
    fn start_payout(&self, driver_id: Uuid, amount: Decimal) -> String;
}

/// Dev/test provider — references are UUIDs and payouts settle instantly.
pub struct MockProvider;

impl PaymentProvider for MockProvider {
    fn name(&self) -> &'static str {
        "mock"
    }
    fn start_topup(&self, _user_id: Uuid, _amount: Decimal) -> String {
        Uuid::new_v4().to_string()
    }
    fn start_payout(&self, _driver_id: Uuid, _amount: Decimal) -> String {
        Uuid::new_v4().to_string()
    }
}

/// Credit a rider's prepaid balance (top-up / bonus / refund). Returns the new balance.
pub async fn credit_rider(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    amount: Decimal,
    txn_type: &str,
    reference: Option<&str>,
    trip_id: Option<Uuid>,
) -> AppResult<Decimal> {
    let (balance,): (Decimal,) = sqlx::query_as(
        "INSERT INTO credit_accounts (user_id, kind, balance, updated_at) \
         VALUES ($1, 'rider', $2, now()) \
         ON CONFLICT (user_id, kind) DO UPDATE SET balance = credit_accounts.balance + $2, updated_at = now() \
         RETURNING balance",
    )
    .bind(user_id)
    .bind(amount)
    .fetch_one(&mut **tx)
    .await?;

    log_txn(
        tx, user_id, "rider", txn_type, amount, balance, reference, trip_id,
    )
    .await?;
    Ok(balance)
}

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

/// Record a driver payout: log the transaction against the driver's kind.
pub async fn log_driver_payout(
    tx: &mut Transaction<'_, Postgres>,
    driver_id: Uuid,
    amount: Decimal,
    balance_after: Decimal,
    reference: &str,
) -> AppResult<()> {
    log_txn(
        tx,
        driver_id,
        "driver",
        "payout",
        -amount,
        balance_after,
        Some(reference),
        None,
    )
    .await
}

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
