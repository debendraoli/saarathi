//! Ops insights: ride history (with ratings, status, cancellations), the
//! complaints/cancellations feed, and filterable leaderboards (top earners,
//! best rated, most cancellations). Mostly staff-gated read-only views, plus
//! (AdminUser-gated) suspend/reactivate on rider accounts — the one write
//! action here, since account status is the one thing about a rider this
//! directory has never been able to change.

use crate::auth::{AdminUser, StaffUser};
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::extract::{Path, Query, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/admin/rides", get(rides))
        .route("/v1/admin/cancellations", get(cancellations))
        .route("/v1/admin/leaderboard", get(leaderboard))
        .route("/v1/admin/riders", get(riders))
        .route("/v1/admin/riders/{id}", get(rider_detail))
        .route("/v1/admin/riders/{id}/suspend", post(suspend_rider))
        .route("/v1/admin/riders/{id}/reactivate", post(reactivate_rider))
        .route("/v1/admin/driver-analytics/{id}", get(driver_analytics))
        .route("/v1/admin/driver-directory", get(driver_directory))
}

#[derive(Serialize, sqlx::FromRow)]
struct RideRow {
    id: Uuid,
    rider_id: Uuid,
    rider_name: Option<String>,
    driver_id: Option<Uuid>,
    driver_name: Option<String>,
    status: String,
    final_fare: Decimal,
    payment_method: String,
    cancel_reason: Option<String>,
    cancelled_by_role: Option<String>,
    driver_stars: Option<i32>,
    created_at: DateTime<Utc>,
    accepted_at: Option<DateTime<Utc>>,
    completed_at: Option<DateTime<Utc>>,
}

#[derive(Deserialize)]
struct RidesQuery {
    status: Option<String>,
}

async fn rides(
    State(st): State<AppState>,
    _staff: StaffUser,
    Query(q): Query<RidesQuery>,
) -> AppResult<Json<Vec<RideRow>>> {
    let base = "SELECT t.id, t.rider_id, ur.full_name AS rider_name, t.driver_id, \
                ud.full_name AS driver_name, t.status::text AS status, t.final_fare, \
                t.payment_method, t.cancel_reason, t.cancelled_by_role, \
                rt.stars AS driver_stars, t.created_at, t.accepted_at, t.completed_at \
         FROM trips t \
         JOIN users ur ON ur.id = t.rider_id \
         LEFT JOIN users ud ON ud.id = t.driver_id \
         LEFT JOIN ratings rt ON rt.trip_id = t.id AND rt.role = 'rider_rates_driver' ";

    let rows: Vec<RideRow> = match q.status.as_deref() {
        Some(s) if !s.is_empty() => {
            sqlx::query_as(sqlx::AssertSqlSafe(format!(
                "{base} WHERE t.status::text = $1 ORDER BY t.created_at DESC LIMIT 200"
            )))
            .bind(s)
            .fetch_all(&st.db)
            .await?
        }
        _ => {
            sqlx::query_as(sqlx::AssertSqlSafe(format!("{base} ORDER BY t.created_at DESC LIMIT 200")))
                .fetch_all(&st.db)
                .await?
        }
    };
    Ok(Json(rows))
}

async fn cancellations(
    State(st): State<AppState>,
    _staff: StaffUser,
) -> AppResult<Json<Vec<RideRow>>> {
    let rows: Vec<RideRow> = sqlx::query_as(
        "SELECT t.id, t.rider_id, ur.full_name AS rider_name, t.driver_id, \
                ud.full_name AS driver_name, t.status::text AS status, t.final_fare, \
                t.payment_method, t.cancel_reason, t.cancelled_by_role, \
                NULL::int AS driver_stars, t.created_at, t.accepted_at, t.completed_at \
         FROM trips t \
         JOIN users ur ON ur.id = t.rider_id \
         LEFT JOIN users ud ON ud.id = t.driver_id \
         WHERE t.status = 'cancelled' ORDER BY t.created_at DESC LIMIT 200",
    )
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Serialize, sqlx::FromRow)]
struct LeaderRow {
    user_id: Uuid,
    name: Option<String>,
    phone: String,
    value: f64,
}

#[derive(Deserialize)]
struct LeaderQuery {
    role: Option<String>, // driver | rider
    by: Option<String>,   // earnings | rating | cancellations | trips
}

async fn leaderboard(
    State(st): State<AppState>,
    _staff: StaffUser,
    Query(q): Query<LeaderQuery>,
) -> AppResult<Json<Vec<LeaderRow>>> {
    let role = q.role.as_deref().unwrap_or("driver");
    let by = q.by.as_deref().unwrap_or("earnings");

    let sql: &str = match (role, by) {
        ("driver", "earnings") =>
            "SELECT le.driver_id AS user_id, u.full_name AS name, u.phone, \
                    SUM(le.driver_payout)::float8 AS value \
             FROM ledger_entries le JOIN users u ON u.id = le.driver_id \
             GROUP BY le.driver_id, u.full_name, u.phone ORDER BY value DESC LIMIT 20",
        ("driver", "rating") =>
            "SELECT ra.ratee_id AS user_id, u.full_name AS name, u.phone, \
                    AVG(ra.stars)::float8 AS value \
             FROM ratings ra JOIN users u ON u.id = ra.ratee_id \
             WHERE ra.role = 'rider_rates_driver' \
             GROUP BY ra.ratee_id, u.full_name, u.phone ORDER BY value DESC LIMIT 20",
        ("driver", "cancellations") =>
            "SELECT t.cancelled_by AS user_id, u.full_name AS name, u.phone, count(*)::float8 AS value \
             FROM trips t JOIN users u ON u.id = t.cancelled_by \
             WHERE t.status = 'cancelled' AND t.cancelled_by_role = 'driver' \
             GROUP BY t.cancelled_by, u.full_name, u.phone ORDER BY value DESC LIMIT 20",
        ("rider", "cancellations") =>
            "SELECT t.cancelled_by AS user_id, u.full_name AS name, u.phone, count(*)::float8 AS value \
             FROM trips t JOIN users u ON u.id = t.cancelled_by \
             WHERE t.status = 'cancelled' AND t.cancelled_by_role = 'rider' \
             GROUP BY t.cancelled_by, u.full_name, u.phone ORDER BY value DESC LIMIT 20",
        ("rider", "trips") =>
            "SELECT t.rider_id AS user_id, u.full_name AS name, u.phone, count(*)::float8 AS value \
             FROM trips t JOIN users u ON u.id = t.rider_id \
             GROUP BY t.rider_id, u.full_name, u.phone ORDER BY value DESC LIMIT 20",
        _ => return Err(AppError::BadRequest("unsupported role/by combination".into())),
    };

    let rows: Vec<LeaderRow> = sqlx::query_as(sql).fetch_all(&st.db).await?;
    Ok(Json(rows))
}

// ── Riders directory ─────────────────────────────────────────────────────────
// Owned here (not auth, which owns the `users` table) because a useful rider
// row needs trip/spend aggregates that only exist in rides' own schema — same
// cross-schema-read-in-one-query convention `rides` already uses elsewhere in
// this file (`JOIN users` against auth's table from rides' own pool).

#[derive(Serialize, sqlx::FromRow)]
struct RiderRow {
    id: Uuid,
    phone: String,
    full_name: Option<String>,
    status: String,
    created_at: DateTime<Utc>,
    total_rides: i64,
    total_spend: Decimal,
}

#[derive(Deserialize)]
struct RidersQuery {
    #[serde(default)]
    q: String,
}

async fn riders(
    State(st): State<AppState>,
    _staff: StaffUser,
    Query(q): Query<RidersQuery>,
) -> AppResult<Json<Vec<RiderRow>>> {
    let query = q.q.trim().to_string();
    let rows: Vec<RiderRow> = sqlx::query_as(
        "SELECT u.id, u.phone, u.full_name, u.status::text AS status, u.created_at, \
                COALESCE(agg.total_rides, 0) AS total_rides, \
                COALESCE(agg.total_spend, 0) AS total_spend \
         FROM users u \
         LEFT JOIN ( \
             SELECT rider_id, count(*) FILTER (WHERE status = 'completed') AS total_rides, \
                    SUM(final_fare) FILTER (WHERE status = 'completed') AS total_spend \
             FROM trips GROUP BY rider_id \
         ) agg ON agg.rider_id = u.id \
         WHERE u.role = 'rider' \
           AND ($1 = '' OR u.phone ILIKE '%' || $1 || '%' OR u.full_name ILIKE '%' || $1 || '%') \
         ORDER BY u.created_at DESC LIMIT 200",
    )
    .bind(&query)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Serialize)]
struct RiderDetail {
    id: Uuid,
    phone: String,
    full_name: Option<String>,
    status: String,
    created_at: DateTime<Utc>,
    total_rides: i64,
    completed_rides: i64,
    cancelled_rides: i64,
    total_spend: Decimal,
    avg_rating: Option<f64>,
    rating_count: i64,
    recent_trips: Vec<RideRow>,
}

async fn rider_detail(
    State(st): State<AppState>,
    _staff: StaffUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<RiderDetail>> {
    let user: Option<(String, Option<String>, String, DateTime<Utc>)> = sqlx::query_as(
        "SELECT phone, full_name, status::text, created_at FROM users WHERE id = $1 AND role = 'rider'",
    )
    .bind(id)
    .fetch_optional(&st.db)
    .await?;
    let (phone, full_name, status, created_at) = user.ok_or(AppError::NotFound)?;

    let (total_rides, completed_rides, cancelled_rides, total_spend): (i64, i64, i64, Decimal) =
        sqlx::query_as(
            "SELECT count(*), \
                    count(*) FILTER (WHERE status = 'completed'), \
                    count(*) FILTER (WHERE status = 'cancelled'), \
                    COALESCE(SUM(final_fare) FILTER (WHERE status = 'completed'), 0) \
             FROM trips WHERE rider_id = $1",
        )
        .bind(id)
        .fetch_one(&st.db)
        .await?;

    let (avg_rating, rating_count): (Option<f64>, i64) = sqlx::query_as(
        "SELECT AVG(stars)::float8, count(*) FROM ratings \
         WHERE ratee_id = $1 AND role = 'driver_rates_rider'",
    )
    .bind(id)
    .fetch_one(&st.db)
    .await?;

    let recent_trips: Vec<RideRow> = sqlx::query_as(
        "SELECT t.id, t.rider_id, ur.full_name AS rider_name, t.driver_id, \
                ud.full_name AS driver_name, t.status::text AS status, t.final_fare, \
                t.payment_method, t.cancel_reason, t.cancelled_by_role, \
                rt.stars AS driver_stars, t.created_at, t.accepted_at, t.completed_at \
         FROM trips t \
         JOIN users ur ON ur.id = t.rider_id \
         LEFT JOIN users ud ON ud.id = t.driver_id \
         LEFT JOIN ratings rt ON rt.trip_id = t.id AND rt.role = 'rider_rates_driver' \
         WHERE t.rider_id = $1 ORDER BY t.created_at DESC LIMIT 20",
    )
    .bind(id)
    .fetch_all(&st.db)
    .await?;

    Ok(Json(RiderDetail {
        id,
        phone,
        full_name,
        status,
        created_at,
        total_rides,
        completed_rides,
        cancelled_rides,
        total_spend,
        avg_rating,
        rating_count,
        recent_trips,
    }))
}

async fn set_rider_status(
    st: &AppState,
    id: Uuid,
    status: &str,
) -> AppResult<Json<serde_json::Value>> {
    let updated: Option<(Uuid,)> = sqlx::query_as(
        "UPDATE users SET status = $2::user_status WHERE id = $1 AND role = 'rider' RETURNING id",
    )
    .bind(id)
    .bind(status)
    .fetch_optional(&st.db)
    .await?;
    updated.ok_or(AppError::NotFound)?;
    Ok(Json(json!({ "ok": true, "status": status })))
}

/// Suspends a rider account — they can no longer sign in. Doesn't touch any
/// in-progress trip; that's a separate concern (cancellation/SOS flows).
async fn suspend_rider(
    State(st): State<AppState>,
    _admin: AdminUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<serde_json::Value>> {
    set_rider_status(&st, id, "suspended").await
}

async fn reactivate_rider(
    State(st): State<AppState>,
    _admin: AdminUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<serde_json::Value>> {
    set_rider_status(&st, id, "active").await
}

// ── Per-driver analytics ─────────────────────────────────────────────────────
// Separate from auth's /v1/admin/drivers/{id} (KYC profile — driver row PK) —
// this takes the underlying *user* id, since that's what trips/ratings/
// ledger_entries key on. Named distinctly (not nested under /v1/admin/drivers)
// so the gateway's existing PathPrefix(`/v1/admin/drivers`) rule, already
// routed to auth, doesn't need touching.

#[derive(Serialize)]
struct DriverAnalytics {
    user_id: Uuid,
    total_trips: i64,
    completed_trips: i64,
    cancelled_trips: i64,
    total_earnings: Decimal,
    avg_rating: Option<f64>,
    rating_count: i64,
    recent_trips: Vec<RideRow>,
}

async fn driver_analytics(
    State(st): State<AppState>,
    _staff: StaffUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<DriverAnalytics>> {
    let (total_trips, completed_trips, cancelled_trips): (i64, i64, i64) = sqlx::query_as(
        "SELECT count(*), \
                count(*) FILTER (WHERE status = 'completed'), \
                count(*) FILTER (WHERE status = 'cancelled') \
         FROM trips WHERE driver_id = $1",
    )
    .bind(id)
    .fetch_one(&st.db)
    .await?;

    let total_earnings: Decimal = sqlx::query_scalar(
        "SELECT COALESCE(SUM(driver_payout), 0) FROM ledger_entries WHERE driver_id = $1",
    )
    .bind(id)
    .fetch_one(&st.db)
    .await?;

    let (avg_rating, rating_count): (Option<f64>, i64) = sqlx::query_as(
        "SELECT AVG(stars)::float8, count(*) FROM ratings \
         WHERE ratee_id = $1 AND role = 'rider_rates_driver'",
    )
    .bind(id)
    .fetch_one(&st.db)
    .await?;

    let recent_trips: Vec<RideRow> = sqlx::query_as(
        "SELECT t.id, t.rider_id, ur.full_name AS rider_name, t.driver_id, \
                ud.full_name AS driver_name, t.status::text AS status, t.final_fare, \
                t.payment_method, t.cancel_reason, t.cancelled_by_role, \
                rt.stars AS driver_stars, t.created_at, t.accepted_at, t.completed_at \
         FROM trips t \
         JOIN users ur ON ur.id = t.rider_id \
         LEFT JOIN users ud ON ud.id = t.driver_id \
         LEFT JOIN ratings rt ON rt.trip_id = t.id AND rt.role = 'rider_rates_driver' \
         WHERE t.driver_id = $1 ORDER BY t.created_at DESC LIMIT 20",
    )
    .bind(id)
    .fetch_all(&st.db)
    .await?;

    Ok(Json(DriverAnalytics {
        user_id: id,
        total_trips,
        completed_trips,
        cancelled_trips,
        total_earnings,
        avg_rating,
        rating_count,
        recent_trips,
    }))
}

// ── Driver directory ─────────────────────────────────────────────────────────
// Every driver (any KYC status), unlike auth's /v1/admin/drivers which is the
// review queue (status=queue|rejected only) — this is the "browse everyone"
// counterpart to the riders directory above, same reasoning for living here:
// trip/earnings aggregates only exist in rides' own schema. Returns the
// `drivers` row id (not just the user id) so the dashboard can link straight
// into auth's existing per-driver KYC detail page.

#[derive(Serialize, sqlx::FromRow)]
struct DriverDirectoryRow {
    driver_id: Uuid,
    user_id: Uuid,
    phone: String,
    full_name: Option<String>,
    kyc_status: String,
    created_at: DateTime<Utc>,
    total_trips: i64,
    total_earnings: Decimal,
}

async fn driver_directory(
    State(st): State<AppState>,
    _staff: StaffUser,
    Query(q): Query<RidersQuery>,
) -> AppResult<Json<Vec<DriverDirectoryRow>>> {
    let query = q.q.trim().to_string();
    let rows: Vec<DriverDirectoryRow> = sqlx::query_as(
        "SELECT d.id AS driver_id, u.id AS user_id, u.phone, u.full_name, \
                d.kyc_status::text AS kyc_status, u.created_at, \
                COALESCE(t.total_trips, 0) AS total_trips, \
                COALESCE(le.total_earnings, 0) AS total_earnings \
         FROM drivers d \
         JOIN users u ON u.id = d.user_id \
         LEFT JOIN ( \
             SELECT driver_id, count(*) FILTER (WHERE status = 'completed') AS total_trips \
             FROM trips GROUP BY driver_id \
         ) t ON t.driver_id = u.id \
         LEFT JOIN ( \
             SELECT driver_id, SUM(driver_payout) AS total_earnings \
             FROM ledger_entries GROUP BY driver_id \
         ) le ON le.driver_id = u.id \
         WHERE ($1 = '' OR u.phone ILIKE '%' || $1 || '%' OR u.full_name ILIKE '%' || $1 || '%') \
         ORDER BY u.created_at DESC LIMIT 200",
    )
    .bind(&query)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}
