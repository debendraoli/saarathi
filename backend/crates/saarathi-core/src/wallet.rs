//! Wallet & credit accounting — the **single source of truth** for money
//! movement across services. Both the rides trip-settlement path and the
//! `saarathi-payments` operations call these; there is exactly one
//! implementation of each credit/debit so behaviour can never drift.
//!
//! All mutating helpers take a caller-owned `&mut Transaction` so the caller
//! controls atomicity (rides settles inside the trip tx; payments runs its own).

use crate::api::ErrorCode;
use rust_decimal::Decimal;
use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

#[derive(Debug, thiserror::Error)]
pub enum WalletError {
    #[error("insufficient credits")]
    InsufficientRiderCredits,
    #[error(transparent)]
    Db(#[from] sqlx::Error),
}

impl WalletError {
    /// Machine code for the API error envelope (business errors only).
    pub fn code(&self) -> Option<ErrorCode> {
        match self {
            WalletError::InsufficientRiderCredits => Some(ErrorCode::InsufficientCredits),
            WalletError::Db(_) => None,
        }
    }
}

type Result<T> = std::result::Result<T, WalletError>;

/// Credit a rider's prepaid balance (top-up / bonus / refund). Returns new balance.
pub async fn credit_rider(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    amount: Decimal,
    txn_type: &str,
    reference: Option<&str>,
    trip_id: Option<Uuid>,
) -> Result<Decimal> {
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
) -> Result<Decimal> {
    let current: Option<(Decimal,)> = sqlx::query_as(
        "SELECT balance FROM credit_accounts WHERE user_id = $1 AND kind = 'rider' FOR UPDATE",
    )
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await?;
    let balance = current.map(|b| b.0).unwrap_or(Decimal::ZERO);
    if balance < amount {
        return Err(WalletError::InsufficientRiderCredits);
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

/// Credit a driver's prepaid credit account (top-up / fair-cap refund).
pub async fn credit_driver(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    amount: Decimal,
    txn_type: &str,
    reference: Option<&str>,
) -> Result<Decimal> {
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

/// Draw the platform's per-ride cut (commission + accident fund) from a
/// driver's prepaid credit balance on a cash trip — the credit-funded
/// alternative to the old cash-owed-on-wallet debt (doc 13 §4.1). Unlike
/// [`credit_driver`]'s voluntary-spend sibling, this always succeeds and may
/// take the balance negative: the ride already happened, so settlement can't
/// fail on it. The dispatch-time credit floor (accept_offer) is what keeps
/// this the uncommon case, not a hard block here.
pub async fn settle_driver_fee(
    tx: &mut Transaction<'_, Postgres>,
    driver_id: Uuid,
    amount: Decimal,
    trip_id: Uuid,
) -> Result<Decimal> {
    let (balance,): (Decimal,) = sqlx::query_as(
        "INSERT INTO credit_accounts (user_id, kind, balance, updated_at) \
         VALUES ($1, 'driver', -$2, now()) \
         ON CONFLICT (user_id, kind) DO UPDATE SET balance = credit_accounts.balance - $2, updated_at = now() \
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
        "fee",
        -amount,
        balance,
        None,
        Some(trip_id),
    )
    .await?;
    Ok(balance)
}

/// Credit a driver's earnings wallet (withdrawable). Used for platform-funded
/// driver incentives / campaign bonuses. Returns the new wallet balance.
pub async fn credit_driver_wallet(
    tx: &mut Transaction<'_, Postgres>,
    driver_id: Uuid,
    amount: Decimal,
    reference: &str,
) -> Result<Decimal> {
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

/// Debit a driver's earnings wallet — e.g. COD cash they collected and now owe
/// to the sender. May drive the balance negative; a settlement gate handles that.
pub async fn debit_driver_wallet(
    tx: &mut Transaction<'_, Postgres>,
    driver_id: Uuid,
    amount: Decimal,
    txn_type: &str,
    reference: &str,
) -> Result<Decimal> {
    let (balance,): (Decimal,) = sqlx::query_as(
        "INSERT INTO driver_wallets (driver_id, balance, updated_at) VALUES ($1, -$2, now()) \
         ON CONFLICT (driver_id) DO UPDATE SET balance = driver_wallets.balance - $2, updated_at = now() \
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
        txn_type,
        -amount,
        balance,
        Some(reference),
        None,
    )
    .await?;
    Ok(balance)
}

/// Record a driver payout (the wallet is debited by the caller in the same tx).
pub async fn log_driver_payout(
    tx: &mut Transaction<'_, Postgres>,
    driver_id: Uuid,
    amount: Decimal,
    balance_after: Decimal,
    reference: &str,
) -> Result<()> {
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

/// Reverse a failed driver payout: log the wallet re-credit.
pub async fn log_driver_refund(
    tx: &mut Transaction<'_, Postgres>,
    driver_id: Uuid,
    amount: Decimal,
    balance_after: Decimal,
    reference: &str,
) -> Result<()> {
    log_txn(
        tx,
        driver_id,
        "driver",
        "refund",
        amount,
        balance_after,
        Some(reference),
        None,
    )
    .await
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
) -> Result<()> {
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
pub async fn rider_balance(pool: &PgPool, user_id: Uuid) -> Result<Decimal> {
    let bal: Option<(Decimal,)> =
        sqlx::query_as("SELECT balance FROM credit_accounts WHERE user_id = $1 AND kind = 'rider'")
            .bind(user_id)
            .fetch_optional(pool)
            .await?;
    Ok(bal.map(|b| b.0).unwrap_or(Decimal::ZERO))
}

/// Current prepaid credit balance for a driver (read-only).
pub async fn driver_credit_balance(pool: &PgPool, user_id: Uuid) -> Result<Decimal> {
    let bal: Option<(Decimal,)> = sqlx::query_as(
        "SELECT balance FROM credit_accounts WHERE user_id = $1 AND kind = 'driver'",
    )
    .bind(user_id)
    .fetch_optional(pool)
    .await?;
    Ok(bal.map(|b| b.0).unwrap_or(Decimal::ZERO))
}

