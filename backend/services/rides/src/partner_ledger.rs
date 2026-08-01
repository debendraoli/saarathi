//! Partner money: an append-only, hash-chained ledger + a running wallet
//! balance (doc 14, Phase 2). A partner earns a revenue-share carved from the
//! platform's ≤10% commission (never the driver's ≥90%) and prepays a wallet to
//! fund fleet promos. `balance` is +ve when the platform owes the partner.

use crate::error::AppResult;
use rust_decimal::Decimal;
use saarathi_core::ledger::{chain_hash, GENESIS_HASH};
use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

/// Append one signed movement to the partner chain and move the wallet, atomically.
/// `amount` is signed (+ owed to partner, − spent/withdrawn). Returns the new balance.
pub async fn append(
    tx: &mut Transaction<'_, Postgres>,
    partner_id: Uuid,
    trip_id: Option<Uuid>,
    kind: &str,
    amount: Decimal,
) -> AppResult<Decimal> {
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

pub async fn balance(pool: &PgPool, partner_id: Uuid) -> AppResult<Decimal> {
    let b: Option<(Decimal,)> =
        sqlx::query_as("SELECT balance FROM partner_wallets WHERE partner_id = $1")
            .bind(partner_id)
            .fetch_optional(pool)
            .await?;
    Ok(b.map(|x| x.0).unwrap_or(Decimal::ZERO))
}

/// If the trip's driver belongs to an active fleet, accrue that partner's
/// revenue-share: `min(gross × commission_share, commission)` — carved from the
/// platform's commission so it can never dip into the driver's mandated 90%.
pub async fn accrue_commission_share(
    tx: &mut Transaction<'_, Postgres>,
    driver_user_id: Uuid,
    trip_id: Uuid,
    gross: Decimal,
    commission: Decimal,
) -> AppResult<Decimal> {
    let row: Option<(Uuid, Decimal)> = sqlx::query_as(
        "SELECT p.id, p.commission_share FROM partner_drivers pd JOIN partners p ON p.id = pd.partner_id \
         WHERE pd.driver_user_id = $1 AND pd.status = 'active' AND p.status = 'active'",
    )
    .bind(driver_user_id)
    .fetch_optional(&mut **tx)
    .await?;
    let Some((partner_id, share_rate)) = row else {
        return Ok(Decimal::ZERO);
    };
    if share_rate <= Decimal::ZERO {
        return Ok(Decimal::ZERO);
    }
    let share = (gross * share_rate).round_dp(2).min(commission);
    if share <= Decimal::ZERO {
        return Ok(Decimal::ZERO);
    }
    append(tx, partner_id, Some(trip_id), "commission_share", share).await?;
    Ok(share)
}
