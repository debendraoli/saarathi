//! Driver-side campaign bonuses (incentives / quests).
//!
//! When a driver-audience campaign is live, a completed trip earns the driver a
//! **platform-funded** bonus credited to their withdrawable earnings wallet. The
//! rider's fare and the legal ledger split are untouched — this is pure driver
//! incentive spend, recorded for audit in `driver_bonus_grants` +
//! `campaign_redemptions`.

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
    let candidates: Vec<DriverCampaign> = sqlx::query_as(
        "SELECT id, kind::text, value, max_discount, rules \
         FROM campaigns \
         WHERE audience = 'driver' AND active = true \
           AND (starts_at IS NULL OR starts_at <= now()) \
           AND (ends_at IS NULL OR ends_at >= now()) \
           AND (vehicle_class IS NULL OR vehicle_class = $1) \
           AND min_fare <= $2 \
           AND (usage_limit IS NULL OR used_count < usage_limit) \
         ORDER BY value DESC",
    )
    .bind(vehicle_class)
    .bind(gross)
    .fetch_all(&mut **tx)
    .await?;

    // Highest-value campaign whose dynamic rules pass for this driver.
    let mut chosen: Option<DriverCampaign> = None;
    for c in candidates {
        if c.rules.0.is_empty() {
            chosen = Some(c);
            break;
        }
        let ctx =
            crate::rules::load_context(pool, driver_id, "driver", c.id, gross, Some(trip_id)).await;
        if crate::rules::evaluate(&c.rules.0, &ctx) {
            chosen = Some(c);
            break;
        }
    }
    let Some(c) = chosen else {
        return Ok(Decimal::ZERO);
    };

    let mut bonus = match c.kind.as_str() {
        "percent" => (gross * c.value / dec!(100)).round_dp(2),
        _ => c.value,
    };
    if let Some(cap) = c.max_discount {
        if bonus > cap {
            bonus = cap;
        }
    }
    if bonus <= Decimal::ZERO {
        return Ok(Decimal::ZERO);
    }

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
    Ok(bonus)
}
