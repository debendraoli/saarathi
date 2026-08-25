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

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal_macros::dec;
    use serde_json::json;

    #[test]
    fn all_days_is_all_seven_bits_set() {
        assert_eq!(all_days(), 0b111_1111);
    }

    #[test]
    fn parse_rules_accepts_an_empty_list() {
        assert!(parse_rules(&json!([])).unwrap().is_empty());
    }

    #[test]
    fn parse_rules_accepts_every_known_rule_variant() {
        let rules = parse_rules(&json!([
            {"type": "new_user", "within_days": 30, "max_prior_rides": 0},
            {"type": "new_user"}, // both fields optional
            {"type": "min_rides", "count": 5},
            {"type": "max_rides", "count": 100},
            {"type": "rides_today", "count": 3},
            {"type": "time_of_day", "start_minute": 420, "end_minute": 600},
            {"type": "time_of_day", "start_minute": 0, "end_minute": 60, "days_mask": 0b0000001},
            {"type": "min_fare", "amount": "150.00"},
            {"type": "max_per_user", "count": 1},
        ]))
        .expect("all variants should parse");
        assert_eq!(rules.len(), 9);
    }

    #[test]
    fn time_of_day_defaults_days_mask_to_all_days_when_omitted() {
        let rules = parse_rules(&json!([
            {"type": "time_of_day", "start_minute": 0, "end_minute": 60}
        ]))
        .unwrap();
        match &rules[0] {
            CampaignRule::TimeOfDay { days_mask, .. } => assert_eq!(*days_mask, all_days()),
            other => panic!("expected TimeOfDay, got {other:?}"),
        }
    }

    #[test]
    fn min_fare_parses_the_decimal_amount() {
        let rules = parse_rules(&json!([{"type": "min_fare", "amount": "199.50"}])).unwrap();
        match &rules[0] {
            CampaignRule::MinFare { amount } => assert_eq!(*amount, dec!(199.50)),
            other => panic!("expected MinFare, got {other:?}"),
        }
    }

    #[test]
    fn rejects_an_unknown_rule_type() {
        let err = parse_rules(&json!([{"type": "not_a_real_rule"}])).unwrap_err();
        assert!(err.contains("invalid rules"), "got: {err}");
    }

    #[test]
    fn rejects_a_rule_missing_its_required_field() {
        // min_rides requires `count` — dropping it must fail loudly, not
        // silently default to a permissive rule.
        let err = parse_rules(&json!([{"type": "min_rides"}])).unwrap_err();
        assert!(err.contains("invalid rules"), "got: {err}");
    }

    #[test]
    fn rejects_a_non_array_payload() {
        assert!(parse_rules(&json!({"type": "min_rides", "count": 1})).is_err());
    }
}
