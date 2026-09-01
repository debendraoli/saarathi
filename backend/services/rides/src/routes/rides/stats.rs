//! Rider-facing self-service ride stats.

use crate::auth::AuthUser;
use crate::error::AppResult;
use crate::state::AppState;
use axum::extract::State;
use axum::Json;
use rust_decimal::Decimal;
use serde_json::{Value, json};

/// Self-service mirror of the staff-only `rider_detail` aggregate
/// (`insights.rs`) — same shape, gated to the caller's own id instead of a
/// staff-picked `Path(id)`, and without the account-metadata/recent-trips
/// fields that only make sense in a staff detail view (the Activity tab
/// already covers "my recent trips").
pub(super) async fn my_stats(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Value>> {
    let (total_rides, completed_rides, cancelled_rides, total_spend, total_distance_km): (
        i64,
        i64,
        i64,
        Decimal,
        Decimal,
    ) = sqlx::query_as(
        "SELECT count(*), \
                count(*) FILTER (WHERE status = 'completed'), \
                count(*) FILTER (WHERE status = 'cancelled'), \
                COALESCE(SUM(final_fare) FILTER (WHERE status = 'completed'), 0), \
                COALESCE(SUM(distance_km) FILTER (WHERE status = 'completed'), 0) \
         FROM trips WHERE rider_id = $1",
    )
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await?;

    // The rating the rider has *received* from drivers, not given.
    let (avg_rating, rating_count): (Option<f64>, i64) = sqlx::query_as(
        "SELECT AVG(stars)::float8, count(*) FROM ratings \
         WHERE ratee_id = $1 AND role = 'driver_rates_rider'",
    )
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await?;

    Ok(Json(json!({
        "total_rides": total_rides,
        "completed_rides": completed_rides,
        "cancelled_rides": cancelled_rides,
        "total_spend": total_spend,
        "total_distance_km": total_distance_km,
        "avg_rating": avg_rating,
        "rating_count": rating_count,
    })))
}
