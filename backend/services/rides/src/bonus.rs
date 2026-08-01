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
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

#[derive(sqlx::FromRow)]
struct DriverCampaign {
    id: Uuid,
    kind: String,
    value: Decimal,
    max_discount: Option<Decimal>,
}

/// Apply the best-matching active driver campaign to a completed trip. Returns
/// the bonus amount granted (0 if none applied). Runs inside the caller's tx.
pub async fn grant_driver_bonus(
    tx: &mut Transaction<'_, Postgres>,
    driver_id: Uuid,
    trip_id: Uuid,
    gross: Decimal,
    vehicle_class: &str,
) -> AppResult<Decimal> {
    let row: Option<DriverCampaign> = sqlx::query_as(
        "SELECT id, kind::text, value, max_discount \
         FROM campaigns \
         WHERE audience = 'driver' AND active = true \
           AND (starts_at IS NULL OR starts_at <= now()) \
           AND (ends_at IS NULL OR ends_at >= now()) \
           AND (vehicle_class IS NULL OR vehicle_class = $1) \
           AND min_fare <= $2 \
           AND (usage_limit IS NULL OR used_count < usage_limit) \
         ORDER BY value DESC LIMIT 1",
    )
    .bind(vehicle_class)
    .bind(gross)
    .fetch_optional(&mut **tx)
    .await?;

    let Some(c) = row else {
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
