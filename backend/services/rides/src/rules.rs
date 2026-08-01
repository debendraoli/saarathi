//! Dynamic, rule-based campaign eligibility.
//!
//! A campaign carries a list of [`CampaignRule`]s (stored as JSONB). A campaign
//! applies to a given user/trip only when **every** rule passes (AND). This lets
//! ops target, from the dashboard, things like "new customers only", "drivers
//! with more than 50 rides", or "weekday evenings" without a code change.

use chrono::{Datelike, FixedOffset, TimeZone, Timelike, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use uuid::Uuid;

/// Nepal Time is UTC+5:45.
const NPT_OFFSET_SECS: i32 = 5 * 3600 + 45 * 60;

fn all_days() -> i32 {
    127
}

/// One eligibility condition. Serialized in JSONB with a `type` discriminator,
/// e.g. `{ "type": "new_user", "within_days": 30, "max_prior_rides": 0 }`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CampaignRule {
    /// A "new" rider/driver: account age ≤ `within_days` (if set) AND prior
    /// completed rides ≤ `max_prior_rides` (if set). Both optional; omit for any.
    NewUser {
        #[serde(default)]
        within_days: Option<i64>,
        #[serde(default)]
        max_prior_rides: Option<i64>,
    },
    /// The user has at least `count` prior completed rides (in this audience role).
    MinRides { count: i64 },
    /// The user has at most `count` prior completed rides.
    MaxRides { count: i64 },
    /// Active only within a local (NPT) time-of-day window on the given days
    /// (`days_mask` bit0=Sun … bit6=Sat). `end` may wrap past midnight.
    TimeOfDay {
        start_minute: i32,
        end_minute: i32,
        #[serde(default = "all_days")]
        days_mask: i32,
    },
    /// The trip gross fare must be at least `amount`.
    MinFare { amount: Decimal },
    /// The user may redeem this campaign at most `count` times.
    MaxPerUser { count: i64 },
}

/// The facts a rule set is evaluated against, loaded once per (user, campaign).
pub struct RuleContext {
    pub prior_completed_rides: i64,
    pub account_age_days: i64,
    pub user_redemptions: i64,
    pub gross: Decimal,
    pub now_minute: i32,
    pub now_daymask: i32,
}

/// Gather the facts needed to evaluate a campaign's rules for one user.
/// `exclude_trip` keeps the in-flight trip out of the "prior rides" count so a
/// driver completing their Nth ride isn't counted as having N rides yet.
pub async fn load_context(
    pool: &PgPool,
    user_id: Uuid,
    audience: &str,
    campaign_id: Uuid,
    gross: Decimal,
    exclude_trip: Option<Uuid>,
) -> RuleContext {
    let col = if audience == "driver" {
        "driver_id"
    } else {
        "rider_id"
    };
    let prior: i64 = sqlx::query_scalar(&format!(
        "SELECT count(*) FROM trips \
         WHERE status = 'completed' AND {col} = $1 AND ($2::uuid IS NULL OR id <> $2)"
    ))
    .bind(user_id)
    .bind(exclude_trip)
    .fetch_one(pool)
    .await
    .unwrap_or(0);

    let account_age_days: i64 = sqlx::query_scalar(
        "SELECT floor(extract(epoch FROM now() - created_at) / 86400)::bigint \
         FROM users WHERE id = $1",
    )
    .bind(user_id)
    .fetch_optional(pool)
    .await
    .ok()
    .flatten()
    .unwrap_or(0);

    let user_redemptions: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM campaign_redemptions WHERE campaign_id = $1 AND user_id = $2",
    )
    .bind(campaign_id)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .unwrap_or(0);

    let tz = FixedOffset::east_opt(NPT_OFFSET_SECS).expect("valid offset");
    let now = tz.from_utc_datetime(&Utc::now().naive_utc());
    RuleContext {
        prior_completed_rides: prior,
        account_age_days,
        user_redemptions,
        gross,
        now_minute: (now.hour() * 60 + now.minute()) as i32,
        now_daymask: 1_i32 << now.weekday().num_days_from_sunday(),
    }
}

/// A campaign applies only when **all** rules pass.
pub fn evaluate(rules: &[CampaignRule], ctx: &RuleContext) -> bool {
    rules.iter().all(|rule| match rule {
        CampaignRule::NewUser {
            within_days,
            max_prior_rides,
        } => {
            within_days.is_none_or(|d| ctx.account_age_days <= d)
                && max_prior_rides.is_none_or(|m| ctx.prior_completed_rides <= m)
        }
        CampaignRule::MinRides { count } => ctx.prior_completed_rides >= *count,
        CampaignRule::MaxRides { count } => ctx.prior_completed_rides <= *count,
        CampaignRule::TimeOfDay {
            start_minute,
            end_minute,
            days_mask,
        } => {
            if days_mask & ctx.now_daymask == 0 {
                return false;
            }
            let m = ctx.now_minute;
            if start_minute <= end_minute {
                m >= *start_minute && m < *end_minute
            } else {
                m >= *start_minute || m < *end_minute
            }
        }
        CampaignRule::MinFare { amount } => ctx.gross >= *amount,
        CampaignRule::MaxPerUser { count } => ctx.user_redemptions < *count,
    })
}

/// Validate a raw JSON rules payload (from the dashboard) is well-formed.
pub fn parse_rules(value: &serde_json::Value) -> Result<Vec<CampaignRule>, String> {
    serde_json::from_value::<Vec<CampaignRule>>(value.clone())
        .map_err(|e| format!("invalid rules: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal_macros::dec;

    fn ctx(prior: i64, age: i64, reds: i64, gross: Decimal) -> RuleContext {
        RuleContext {
            prior_completed_rides: prior,
            account_age_days: age,
            user_redemptions: reds,
            gross,
            now_minute: 18 * 60,
            now_daymask: 1 << 3, // Wednesday
        }
    }

    #[test]
    fn new_customer_only() {
        let rules = vec![CampaignRule::NewUser {
            within_days: None,
            max_prior_rides: Some(0),
        }];
        assert!(evaluate(&rules, &ctx(0, 100, 0, dec!(50))));
        assert!(!evaluate(&rules, &ctx(3, 1, 0, dec!(50))));
    }

    #[test]
    fn loyalty_min_rides_and_cap() {
        let rules = vec![
            CampaignRule::MinRides { count: 10 },
            CampaignRule::MaxPerUser { count: 1 },
        ];
        assert!(evaluate(&rules, &ctx(10, 200, 0, dec!(50))));
        assert!(!evaluate(&rules, &ctx(9, 200, 0, dec!(50)))); // too few rides
        assert!(!evaluate(&rules, &ctx(10, 200, 1, dec!(50)))); // already redeemed
    }

    #[test]
    fn time_window_and_fare_floor() {
        let rules = vec![
            CampaignRule::TimeOfDay {
                start_minute: 17 * 60,
                end_minute: 20 * 60,
                days_mask: all_days(),
            },
            CampaignRule::MinFare { amount: dec!(40) },
        ];
        assert!(evaluate(&rules, &ctx(0, 1, 0, dec!(50)))); // 18:00, fare 50
        assert!(!evaluate(&rules, &ctx(0, 1, 0, dec!(20)))); // fare too low
    }
}
