//! Wallet/ledger writes for **payment operations** (top-ups, payouts, PSP
//! callbacks). These write the same `credit_accounts` / `credit_transactions` /
//! `driver_wallets` / `partner_ledger` tables that the rides trip-settlement path
//! writes — both services share one Postgres DB (settlement stays atomic inside
//! the trip transaction; operations run as their own transactions here). The
//! partner-ledger append mirrors rides' exactly and uses the same
//! `saarathi_core::ledger` hash so `verify_chain` stays intact across services.

use crate::error::AppResult;
use rust_decimal::Decimal;
use saarathi_core::ledger::{chain_hash, GENESIS_HASH};
use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

pub async fn rider_balance(pool: &PgPool, user_id: Uuid) -> AppResult<Decimal> {
    let bal: Option<(Decimal,)> =
        sqlx::query_as("SELECT balance FROM credit_accounts WHERE user_id = $1 AND kind = 'rider'")
            .bind(user_id)
            .fetch_optional(pool)
            .await?;
    Ok(bal.map(|b| b.0).unwrap_or(Decimal::ZERO))
}

/// Credit a rider's prepaid balance. Returns the new balance.
pub async fn credit_rider(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    amount: Decimal,
    txn_type: &str,
    reference: Option<&str>,
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
    log_txn(tx, user_id, "rider", txn_type, amount, balance, reference).await?;
    Ok(balance)
}

/// Credit a driver's prepaid credit account. Returns the new balance.
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
    log_txn(tx, user_id, "driver", txn_type, amount, balance, reference).await?;
    Ok(balance)
}

/// Log a driver payout (wallet debited elsewhere in the same tx).
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
    )
    .await
}

/// Log a reversed (failed) driver payout re-crediting the wallet.
pub async fn log_driver_refund(
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
        "refund",
        amount,
        balance_after,
        Some(reference),
    )
    .await
}

async fn log_txn(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    kind: &str,
    txn_type: &str,
    amount: Decimal,
    balance_after: Decimal,
    reference: Option<&str>,
) -> AppResult<()> {
    sqlx::query(
        "INSERT INTO credit_transactions (user_id, kind, txn_type, amount, balance_after, reference) \
         VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(user_id)
    .bind(kind)
    .bind(txn_type)
    .bind(amount)
    .bind(balance_after)
    .bind(reference)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

/// Append one signed movement to the partner hash-chain + move the wallet.
/// Mirrors rides' `partner_ledger::append` byte-for-byte (same payload + hash)
/// so the single global chain stays verifiable across both writers.
pub async fn partner_ledger_append(
    tx: &mut Transaction<'_, Postgres>,
    partner_id: Uuid,
    trip_id: Option<Uuid>,
    kind: &str,
    amount: Decimal,
) -> AppResult<Decimal> {
    sqlx::query("SELECT pg_advisory_xact_lock(770002)")
        .execute(&mut **tx)
        .await?;

    let (balance,): (Decimal,) = sqlx::query_as(
        "INSERT INTO partner_wallets (partner_id, balance, updated_at) VALUES ($1, $2, now()) \
         ON CONFLICT (partner_id) DO UPDATE SET balance = partner_wallets.balance + $2, updated_at = now() \
         RETURNING balance",
    )
    .bind(partner_id)
    .bind(amount)
    .fetch_one(&mut **tx)
    .await?;

    let last: Option<(i64, String)> =
        sqlx::query_as("SELECT seq, entry_hash FROM partner_ledger ORDER BY seq DESC LIMIT 1")
            .fetch_optional(&mut **tx)
            .await?;
    let (prev_seq, prev_hash) = last.unwrap_or((0, GENESIS_HASH.to_string()));
    let seq = prev_seq + 1;
    let created_at_unix = chrono::Utc::now().timestamp();
    let payload = format!(
        "{}|{}|{}|{}|{}|{}",
        partner_id,
        trip_id.map(|t| t.to_string()).unwrap_or_default(),
        kind,
        amount.round_dp(2),
        balance.round_dp(2),
        created_at_unix,
    );
    let entry_hash = chain_hash(seq, &prev_hash, &payload);

    sqlx::query(
        "INSERT INTO partner_ledger \
         (seq, partner_id, trip_id, kind, amount, balance_after, prev_hash, entry_hash, created_at) \
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8, to_timestamp($9))",
    )
    .bind(seq)
    .bind(partner_id)
    .bind(trip_id)
    .bind(kind)
    .bind(amount)
    .bind(balance)
    .bind(&prev_hash)
    .bind(&entry_hash)
    .bind(created_at_unix)
    .execute(&mut **tx)
    .await?;
    Ok(balance)
}
