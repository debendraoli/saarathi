//! Driver-side campaign bonuses (incentives / quests).
//!
//! When a driver-audience campaign is live, a completed trip earns the driver a
//! bonus credited to their withdrawable earnings wallet. **Platform-funded**
//! bonuses are the platform's spend; **partner-funded** fleet bonuses are drawn
//! from the driver's fleet partner wallet. Either way the rider's fare and the
//! legal ledger split are untouched — pure incentive spend, audited in
//! `driver_bonus_grants` + `campaign_redemptions`.

use crate::error::AppResult;
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

#[derive(sqlx::FromRow)]
struct DriverCampaign {
    id: Uuid,
    kind: String,
    value: Decimal,
    max_discount: Option<Decimal>,
    rules: sqlx::types::Json<Vec<crate::rules::CampaignRule>>,
    partner_id: Option<Uuid>,
    funded_by: String,
}

fn compute_bonus(kind: &str, value: Decimal, cap: Option<Decimal>, gross: Decimal) -> Decimal {
    let mut bonus = match kind {
        "percent" => (gross * value / dec!(100)).round_dp(2),
        _ => value,
    };
    if let Some(c) = cap {
        if bonus > c {
            bonus = c;
        }
    }
    bonus
}

/// Apply the best-matching active driver campaign to a completed trip. Returns
/// the bonus amount granted (0 if none applied). Runs inside the caller's tx;
/// `pool` is used for the read-only rule-context lookups.
pub async fn grant_driver_bonus(
    tx: &mut Transaction<'_, Postgres>,
    pool: &PgPool,
    driver_id: Uuid,
    trip_id: Uuid,
    gross: Decimal,
    vehicle_class: &str,
) -> AppResult<Decimal> {
    // The driver's active fleet (if any) — used to include this fleet's own
    // partner-funded campaigns and to exclude every other partner's.
    let fleet: Option<(Uuid,)> = sqlx::query_as(
        "SELECT partner_id FROM partner_drivers WHERE driver_user_id = $1 AND status = 'active'",
    )
    .bind(driver_id)
    .fetch_optional(&mut **tx)
    .await?;
    let fleet_id = fleet.map(|f| f.0);

    // Platform campaigns (partner_id IS NULL) + this driver's own fleet campaigns.
    let candidates: Vec<DriverCampaign> = sqlx::query_as(
        "SELECT id, kind::text, value, max_discount, rules, partner_id, funded_by \
         FROM campaigns \
         WHERE audience = 'driver' AND active = true \
           AND (starts_at IS NULL OR starts_at <= now()) \
           AND (ends_at IS NULL OR ends_at >= now()) \
           AND (vehicle_class IS NULL OR vehicle_class = $1) \
           AND min_fare <= $2 \
           AND (usage_limit IS NULL OR used_count < usage_limit) \
           AND (partner_id IS NULL OR partner_id = $3) \
         ORDER BY value DESC",
    )
    .bind(vehicle_class)
    .bind(gross)
    .bind(fleet_id)
    .fetch_all(&mut **tx)
    .await?;

    // Highest-value campaign whose rules pass and (if partner-funded) whose fleet
    // wallet can cover the bonus.
    let mut chosen: Option<(DriverCampaign, Decimal)> = None;
    for c in candidates {
        if !c.rules.0.is_empty() {
            let ctx =
                crate::rules::load_context(pool, driver_id, "driver", c.id, gross, Some(trip_id))
                    .await;
            if !crate::rules::evaluate(&c.rules.0, &ctx) {
                continue;
            }
        }
        let bonus = compute_bonus(&c.kind, c.value, c.max_discount, gross);
        if bonus <= Decimal::ZERO {
            continue;
        }
        // Partner-funded bonuses require the fleet wallet to cover the spend.
        if c.funded_by == "partner" {
            let Some(pid) = c.partner_id else { continue };
            let bal: Option<(Decimal,)> = sqlx::query_as(
                "SELECT balance FROM partner_wallets WHERE partner_id = $1 FOR UPDATE",
            )
            .bind(pid)
            .fetch_optional(&mut **tx)
            .await?;
            if bal.map(|b| b.0).unwrap_or(Decimal::ZERO) < bonus {
                continue;
            }
        }
        chosen = Some((c, bonus));
        break;
    }
    let Some((c, bonus)) = chosen else {
        return Ok(Decimal::ZERO);
    };

    sqlx::query("UPDATE campaigns SET used_count = used_count + 1 WHERE id = $1")
        .bind(c.id)
        .execute(&mut **tx)
        .await?;
    sqlx::query(
        "INSERT INTO campaign_redemptions (campaign_id, user_id, trip_id, amount) \
         VALUES ($1, $2, $3, $4)",
    )
    .bind(c.id)
    .bind(driver_id)
    .bind(trip_id)
    .bind(bonus)
    .execute(&mut **tx)
    .await?;
    sqlx::query(
        "INSERT INTO driver_bonus_grants (campaign_id, driver_id, trip_id, amount) \
         VALUES ($1, $2, $3, $4)",
    )
    .bind(c.id)
    .bind(driver_id)
    .bind(trip_id)
    .bind(bonus)
    .execute(&mut **tx)
    .await?;

    crate::payments::credit_driver_wallet(tx, driver_id, bonus, &format!("bonus:{trip_id}"))
        .await?;

    // Partner-funded: the fleet pays for the bonus out of its wallet.
    if c.funded_by == "partner" {
        if let Some(pid) = c.partner_id {
            crate::partner_ledger::append(tx, pid, Some(trip_id), "promo_spend", -bonus).await?;
        }
    }
    Ok(bonus)
}
