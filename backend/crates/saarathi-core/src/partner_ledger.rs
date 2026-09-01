//! Partner (fleet) money ledger — the append-only, hash-chained writer shared by
//! rides (revenue-share, corporate charges) and payments (payout reversals).
//! Single implementation so the chain stays verifiable across every writer.

use crate::ledger::{GENESIS_HASH, chain_hash};
use crate::wallet::WalletError;
use rust_decimal::Decimal;
use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

/// Current partner wallet balance (read-only). Zero if the partner has no wallet yet.
pub async fn balance(pool: &PgPool, partner_id: Uuid) -> Result<Decimal, WalletError> {
    let b: Option<(Decimal,)> =
        sqlx::query_as("SELECT balance FROM partner_wallets WHERE partner_id = $1")
            .bind(partner_id)
            .fetch_optional(pool)
            .await?;
    Ok(b.map(|x| x.0).unwrap_or(Decimal::ZERO))
}

#[derive(sqlx::FromRow)]
struct ChainRow {
    seq: i64,
    partner_id: Uuid,
    trip_id: Option<Uuid>,
    kind: String,
    amount: Decimal,
    balance_after: Decimal,
    prev_hash: String,
    entry_hash: String,
    created_at_unix: i64,
}

/// Recompute the whole partner chain and confirm every link + hash is intact.
pub async fn verify_chain(pool: &PgPool) -> Result<bool, WalletError> {
    let rows: Vec<ChainRow> = sqlx::query_as(
        "SELECT seq, partner_id, trip_id, kind, amount, balance_after, prev_hash, entry_hash, \
                extract(epoch FROM created_at)::bigint AS created_at_unix \
         FROM partner_ledger ORDER BY seq",
    )
    .fetch_all(pool)
    .await?;
    let mut expected_prev = GENESIS_HASH.to_string();
    for r in &rows {
        if r.prev_hash != expected_prev {
            return Ok(false);
        }
        let payload = format!(
            "{}|{}|{}|{}|{}|{}",
            r.partner_id,
            r.trip_id.map(|t| t.to_string()).unwrap_or_default(),
            r.kind,
            r.amount.round_dp(2),
            r.balance_after.round_dp(2),
            r.created_at_unix,
        );
        if chain_hash(r.seq, &r.prev_hash, &payload) != r.entry_hash {
            return Ok(false);
        }
        expected_prev = r.entry_hash.clone();
    }
    Ok(true)
}

/// Append one signed movement to the partner chain and move the wallet, atomically.
/// `amount` is signed (+ owed to partner, − spent/withdrawn). A negative amount
/// that would take the wallet below zero is rejected — the lock below is held
/// across the check-then-write so two concurrent debits can't both pass it.
/// Returns the new balance.
pub async fn append(
    tx: &mut Transaction<'_, Postgres>,
    partner_id: Uuid,
    trip_id: Option<Uuid>,
    kind: &str,
    amount: Decimal,
) -> Result<Decimal, WalletError> {
    // Serialize appends so the single global chain stays strictly linear, and
    // so the floor check below can't race a concurrent debit on this partner.
    sqlx::query("SELECT pg_advisory_xact_lock(770002)")
        .execute(&mut **tx)
        .await?;

    if amount < Decimal::ZERO {
        let current: Option<(Decimal,)> =
            sqlx::query_as("SELECT balance FROM partner_wallets WHERE partner_id = $1")
                .bind(partner_id)
                .fetch_optional(&mut **tx)
                .await?;
        let current = current.map(|b| b.0).unwrap_or(Decimal::ZERO);
        if current + amount < Decimal::ZERO {
            return Err(WalletError::InsufficientPartnerBalance);
        }
    }

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
