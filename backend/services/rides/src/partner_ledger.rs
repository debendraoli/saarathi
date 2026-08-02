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
/// Delegates to `saarathi_core::partner_ledger` (the single hash-chain writer).
pub async fn append(
    tx: &mut Transaction<'_, Postgres>,
    partner_id: Uuid,
    trip_id: Option<Uuid>,
    kind: &str,
    amount: Decimal,
) -> AppResult<Decimal> {
    Ok(saarathi_core::partner_ledger::append(tx, partner_id, trip_id, kind, amount).await?)
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

// ── Corporate rider tabs (ride-on-company-tab) ──────────────────────────────

use crate::error::AppError;
use saarathi_core::api::ErrorCode;

/// Pre-flight check for a corporate-tab trip: the rider must be on an active
/// tab whose partner is active, the fleet wallet must cover the fare, and the
/// rider must be within their monthly cap (if any). Read-only (runs at booking).
pub async fn corporate_precheck(
    pool: &PgPool,
    rider_user_id: Uuid,
    amount: Decimal,
) -> AppResult<()> {
    let row: Option<(Uuid, Option<Decimal>)> = sqlx::query_as(
        "SELECT p.id, pr.monthly_cap FROM partner_riders pr JOIN partners p ON p.id = pr.partner_id \
         WHERE pr.rider_user_id = $1 AND pr.status = 'active' AND p.status = 'active'",
    )
    .bind(rider_user_id)
    .fetch_optional(pool)
    .await?;
    let Some((partner_id, cap)) = row else {
        return Err(AppError::Coded(
            axum::http::StatusCode::BAD_REQUEST,
            ErrorCode::CorporateTabUnavailable,
            "you are not on an active corporate tab".into(),
        ));
    };
    if balance(pool, partner_id).await? < amount {
        return Err(AppError::Coded(
            axum::http::StatusCode::BAD_REQUEST,
            ErrorCode::CorporateTabUnavailable,
            "the corporate wallet has insufficient balance".into(),
        ));
    }
    if let Some(cap) = cap {
        let spent: Decimal = sqlx::query_scalar(
            "SELECT coalesce(sum(final_fare), 0) FROM trips \
             WHERE rider_id = $1 AND payment_method = 'corporate' AND status = 'completed' \
               AND created_at >= date_trunc('month', now())",
        )
        .bind(rider_user_id)
        .fetch_one(pool)
        .await?;
        if spent + amount > cap {
            return Err(AppError::Coded(
                axum::http::StatusCode::BAD_REQUEST,
                ErrorCode::CorporateTabUnavailable,
                "monthly corporate spend cap reached".into(),
            ));
        }
    }
    Ok(())
}

/// Charge a completed corporate-tab trip to the rider's partner wallet.
/// Returns the partner's new balance, or `None` if the rider isn't on a tab.
pub async fn charge_corporate_ride(
    tx: &mut Transaction<'_, Postgres>,
    rider_user_id: Uuid,
    trip_id: Uuid,
    amount: Decimal,
) -> AppResult<Option<Decimal>> {
    let row: Option<(Uuid,)> = sqlx::query_as(
        "SELECT p.id FROM partner_riders pr JOIN partners p ON p.id = pr.partner_id \
         WHERE pr.rider_user_id = $1 AND pr.status = 'active' AND p.status = 'active'",
    )
    .bind(rider_user_id)
    .fetch_optional(&mut **tx)
    .await?;
    let Some((partner_id,)) = row else {
        return Ok(None);
    };
    let bal = append(tx, partner_id, Some(trip_id), "ride_charge", -amount).await?;
    Ok(Some(bal))
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
pub async fn verify_chain(pool: &PgPool) -> AppResult<bool> {
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
