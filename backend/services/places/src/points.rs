//! Points/badges rules. Constants, not DB-configurable in v1 — see the
//! feature plan for why (kept simple until there's real usage data to tune
//! against).

use sqlx::PgPool;
use uuid::Uuid;

/// Points granted per approved contribution. Construction/closed-road reports
/// earn more — they're higher effort and higher stakes (a wrong "road
/// closed" report is more disruptive than a wrong building name) so the
/// extra points also mean staff scrutinize them more (reviewers see the
/// point value when triaging).
pub fn points_for(category: &str) -> i32 {
    match category {
        "construction" | "closed_road" => 15,
        _ => 10,
    }
}

/// Persistent places are searchable destinations; transient alerts never are
/// — a "closed road" must never become a pickable drop-off.
pub fn is_navigable(category: &str) -> bool {
    matches!(category, "organisation" | "building" | "landmark" | "sign")
}

pub const POINTS_TO_NPR_RATE: i32 = 10; // 10 points = NPR 1
pub const MIN_REDEEM_POINTS: i32 = 100;

/// Cumulative-approved-count milestones. Checked after every approval;
/// anything newly crossed gets inserted (the UNIQUE constraint on
/// contributor_badges makes this safe to re-check without double-awarding).
const BADGE_THRESHOLDS: [(i32, &str); 3] =
    [(5, "explorer"), (25, "contributor"), (100, "cartographer")];

pub fn badge_title(code: &str) -> &'static str {
    match code {
        "explorer" => "Explorer",
        "contributor" => "Contributor",
        "cartographer" => "Cartographer",
        _ => "Badge",
    }
}

/// Awards any badge the user has newly crossed the threshold for. Returns the
/// badge codes actually inserted (so the caller can notify only about new
/// ones, not ones already held).
pub async fn award_due_badges(pool: &PgPool, user_id: Uuid) -> anyhow::Result<Vec<&'static str>> {
    let approved_count: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM place_contributions WHERE contributor_id = $1 AND status = 'approved'",
    )
    .bind(user_id)
    .fetch_one(pool)
    .await?;

    let mut newly_awarded = Vec::new();
    for (threshold, code) in BADGE_THRESHOLDS {
        if (approved_count as i32) < threshold {
            continue;
        }
        let inserted = sqlx::query(
            "INSERT INTO contributor_badges (user_id, badge_code) VALUES ($1, $2) \
             ON CONFLICT (user_id, badge_code) DO NOTHING",
        )
        .bind(user_id)
        .bind(code)
        .execute(pool)
        .await?;
        if inserted.rows_affected() > 0 {
            newly_awarded.push(code);
        }
    }
    Ok(newly_awarded)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn points_for_gives_construction_and_closed_road_the_higher_rate() {
        assert_eq!(points_for("construction"), 15);
        assert_eq!(points_for("closed_road"), 15);
    }

    #[test]
    fn points_for_defaults_everything_else_to_the_base_rate() {
        assert_eq!(points_for("building"), 10);
        assert_eq!(points_for("landmark"), 10);
        assert_eq!(points_for("unknown_category"), 10);
        assert_eq!(points_for(""), 10);
    }

    #[test]
    fn is_navigable_covers_exactly_the_persistent_categories() {
        for cat in ["organisation", "building", "landmark", "sign"] {
            assert!(is_navigable(cat), "{cat} should be navigable");
        }
    }

    #[test]
    fn is_navigable_excludes_transient_alerts() {
        // A closed-road report must never surface as a pickable destination.
        assert!(!is_navigable("closed_road"));
        assert!(!is_navigable("construction"));
        assert!(!is_navigable("unknown"));
    }

    #[test]
    fn badge_title_maps_known_codes_and_falls_back_for_unknown() {
        assert_eq!(badge_title("explorer"), "Explorer");
        assert_eq!(badge_title("contributor"), "Contributor");
        assert_eq!(badge_title("cartographer"), "Cartographer");
        assert_eq!(badge_title("not_a_real_badge"), "Badge");
    }

    #[test]
    fn badge_thresholds_are_strictly_increasing() {
        // award_due_badges relies on this ordering meaning nothing beyond
        // the loop's implicit assumption — but a badge system with
        // out-of-order thresholds would be a silent design bug, so pin it.
        let thresholds: Vec<i32> = BADGE_THRESHOLDS.iter().map(|(t, _)| *t).collect();
        let mut sorted = thresholds.clone();
        sorted.sort();
        assert_eq!(thresholds, sorted, "BADGE_THRESHOLDS must be listed in increasing order");
    }
}
