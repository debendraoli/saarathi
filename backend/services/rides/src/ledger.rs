//! Ledger persistence + driver-wallet settlement (E2).
//!
//! Appends a hash-chained entry per completed trip and moves the driver wallet.
//! Chain hashing lives in `saarathi_core::ledger`; this is the storage side.

use crate::error::AppResult;
use rust_decimal::Decimal;
use saarathi_core::ledger::{LedgerLink, GENESIS_HASH};
use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

pub struct NewEntry {
    pub trip_id: Uuid,
    pub driver_id: Option<Uuid>,
    pub gross: Decimal,
    pub commission: Decimal,
    pub accident_fund: Decimal,
    pub driver_payout: Decimal,
    pub payment_method: String,
}

/// Append one entry to the chain and settle the driver wallet, atomically.
/// Idempotent per trip. Must run inside the caller's transaction.
pub async fn append(tx: &mut Transaction<'_, Postgres>, e: NewEntry) -> AppResult<String> {
    // Serialize ledger appends so the chain stays strictly linear.
    sqlx::query("SELECT pg_advisory_xact_lock(770001)")
        .execute(&mut **tx)
        .await?;

    // Idempotency: one ledger entry per trip.
    if let Some((existing,)) =
        sqlx::query_as::<_, (String,)>("SELECT entry_hash FROM ledger_entries WHERE trip_id = $1")
            .bind(e.trip_id)
            .fetch_optional(&mut **tx)
            .await?
    {
        return Ok(existing);
    }

    let last: Option<(i64, String)> =
        sqlx::query_as("SELECT seq, entry_hash FROM ledger_entries ORDER BY seq DESC LIMIT 1")
            .fetch_optional(&mut **tx)
            .await?;
    let (prev_seq, prev_hash) = last.unwrap_or((0, GENESIS_HASH.to_string()));
    let seq = prev_seq + 1;
    let created_at_unix = chrono::Utc::now().timestamp();
    let trip_s = e.trip_id.to_string();

    let entry_hash = LedgerLink {
        seq,
        prev_hash: &prev_hash,
        trip_id: &trip_s,
        gross: e.gross,
        commission: e.commission,
        accident_fund: e.accident_fund,
        driver_payout: e.driver_payout,
        payment_method: &e.payment_method,
        created_at_unix,
    }
    .hash();

    sqlx::query(
        "INSERT INTO ledger_entries \
         (seq, trip_id, driver_id, gross, commission, accident_fund, driver_payout, \
          payment_method, prev_hash, entry_hash, created_at) \
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10, to_timestamp($11))",
    )
    .bind(seq)
    .bind(e.trip_id)
    .bind(e.driver_id)
    .bind(e.gross)
    .bind(e.commission)
    .bind(e.accident_fund)
    .bind(e.driver_payout)
    .bind(&e.payment_method)
    .bind(&prev_hash)
    .bind(&entry_hash)
    .bind(created_at_unix)
    .execute(&mut **tx)
    .await?;

    // Cash: driver collected the fare, so owes platform commission + fund.
    // Digital: platform holds the fare, so owes the driver the payout.
    if let Some(driver_id) = e.driver_id {
        let delta: Decimal = if e.payment_method == "cash" {
            -(e.commission + e.accident_fund)
        } else {
            e.driver_payout
        };
        sqlx::query(
            "INSERT INTO driver_wallets (driver_id, balance, updated_at) VALUES ($1, $2, now()) \
             ON CONFLICT (driver_id) DO UPDATE SET balance = driver_wallets.balance + $2, updated_at = now()",
        )
        .bind(driver_id)
        .bind(delta)
        .execute(&mut **tx)
        .await?;
    }

    Ok(entry_hash)
}

#[derive(sqlx::FromRow)]
struct ChainRow {
    seq: i64,
    trip_id: String,
    gross: Decimal,
    commission: Decimal,
    accident_fund: Decimal,
    driver_payout: Decimal,
    payment_method: String,
    prev_hash: String,
    entry_hash: String,
    created_at_unix: i64,
}

/// Recompute the whole chain and confirm every link + hash is intact.
pub async fn verify_chain(pool: &PgPool) -> AppResult<bool> {
    let rows: Vec<ChainRow> = sqlx::query_as(
        "SELECT seq, trip_id::text AS trip_id, gross, commission, accident_fund, driver_payout, \
                payment_method, prev_hash, entry_hash, \
                extract(epoch FROM created_at)::bigint AS created_at_unix \
         FROM ledger_entries ORDER BY seq",
    )
    .fetch_all(pool)
    .await?;

    let mut expected_prev = GENESIS_HASH.to_string();
    for r in &rows {
        if r.prev_hash != expected_prev {
            return Ok(false);
        }
        let recomputed = LedgerLink {
            seq: r.seq,
            prev_hash: &r.prev_hash,
            trip_id: &r.trip_id,
            gross: r.gross,
            commission: r.commission,
            accident_fund: r.accident_fund,
            driver_payout: r.driver_payout,
            payment_method: &r.payment_method,
            created_at_unix: r.created_at_unix,
        }
        .hash();
        if recomputed != r.entry_hash {
            return Ok(false);
        }
        expected_prev = r.entry_hash.clone();
    }
    Ok(true)
}
