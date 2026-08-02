//! Partner (fleet) money ledger — the append-only, hash-chained writer shared by
//! rides (revenue-share, corporate charges) and payments (payout reversals).
//! Single implementation so the chain stays verifiable across every writer.

use crate::ledger::{chain_hash, GENESIS_HASH};
use crate::wallet::WalletError;
use rust_decimal::Decimal;
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

/// Append one signed movement to the partner chain and move the wallet, atomically.
/// `amount` is signed (+ owed to partner, − spent/withdrawn). Returns the new balance.
pub async fn append(
    tx: &mut Transaction<'_, Postgres>,
    partner_id: Uuid,
    trip_id: Option<Uuid>,
    kind: &str,
    amount: Decimal,
) -> Result<Decimal, WalletError> {
    // Serialize appends so the single global chain stays strictly linear.
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
