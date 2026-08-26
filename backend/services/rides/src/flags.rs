//! Feature flags — dashboard-controlled runtime circuit breakers.
//!
//! Flags are read on the hot paths (ride intake, bargaining, surge, dispatch,
//! delivery) so ops can freeze a subsystem from the dashboard without a deploy.
//! Reads are a single indexed primary-key lookup; cheap at launch scale.

use crate::state::AppState;

/// Master switch for accepting new ride requests.
pub const RIDES_NEW_REQUESTS: &str = "rides.new_requests";
/// Allow bounded fare bargaining.
pub const BARGAINING: &str = "rides.bargaining";
/// Apply time-window + supply-based surge (still legally clamped to +20%).
pub const SURGE: &str = "pricing.surge";
/// Run the automatic dispatch / matching engine.
pub const DISPATCH: &str = "dispatch.enabled";
/// Accept parcel / delivery jobs.
pub const DELIVERY: &str = "delivery.enabled";

/// Is `key` enabled? Falls back to `default` if the flag is unknown or the
/// lookup fails (fail-open for reads, so a DB blip never bricks the platform).
pub async fn is_enabled(st: &AppState, key: &str, default: bool) -> bool {
    let row: Option<(bool,)> = sqlx::query_as("SELECT enabled FROM feature_flags WHERE key = $1")
        .bind(key)
        .fetch_optional(&st.db)
        .await
        .unwrap_or(None);
    row.map(|r| r.0).unwrap_or(default)
}
