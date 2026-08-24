//! Campaign eligibility-rule schema, shared by the campaigns service (which
//! validates rules on create) and rides (which evaluates them at estimate /
//! bonus time). Keeping the enum in one place stops the two from drifting.

use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};

pub fn all_days() -> i32 {
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
    /// The user has completed at least `count` rides today (local NPT day).
    /// Distinct from `MinRides` (lifetime) — this is the "daily goal" rule.
    RidesToday { count: i64 },
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

/// Validate a raw JSON rules payload (from the dashboard) is well-formed.
pub fn parse_rules(value: &serde_json::Value) -> Result<Vec<CampaignRule>, String> {
    serde_json::from_value::<Vec<CampaignRule>>(value.clone())
        .map_err(|e| format!("invalid rules: {e}"))
}
