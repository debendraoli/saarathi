//! Platform analytics & event tracking.
//!
//! - Apps + server append lightweight events to `analytics_events` (funnel /
//!   effectiveness signal — kept separate from the money ledger).
//! - The dashboard reads aggregate KPIs to judge platform effectiveness.

use crate::auth::{AuthUser, StaffUser};
use crate::error::AppResult;
use crate::state::AppState;
use axum::extract::{Query, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use rust_decimal::Decimal;
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::PgPool;
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/events", post(record_event))
        .route("/v1/admin/analytics/overview", get(overview))
        .route("/v1/admin/analytics/timeseries", get(timeseries))
}

/// Fire-and-forget server-side event (never fails the caller's request).
pub async fn track(
    pool: &PgPool,
    name: &str,
    user_id: Option<Uuid>,
    role: Option<&str>,
    trip_id: Option<Uuid>,
    props: Value,
) {
    let _ = sqlx::query(
        "INSERT INTO analytics_events (name, user_id, role, trip_id, props) VALUES ($1,$2,$3,$4,$5)",
    )
    .bind(name)
    .bind(user_id)
    .bind(role)
    .bind(trip_id)
    .bind(props)
    .execute(pool)
    .await;
}

#[derive(Deserialize)]
struct EventBody {
    name: String,
    #[serde(default)]
    trip_id: Option<Uuid>,
    #[serde(default)]
    props: Option<Value>,
}

async fn record_event(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<EventBody>,
) -> AppResult<Json<Value>> {
    if body.name.trim().is_empty() {
        return Ok(Json(json!({ "recorded": false })));
    }
    track(
        &st.db,
        body.name.trim(),
        Some(claims.sub),
        Some(&claims.role),
        body.trip_id,
        body.props.unwrap_or_else(|| json!({})),
    )
    .await;
    Ok(Json(json!({ "recorded": true })))
}

#[derive(sqlx::FromRow)]
struct TripAgg {
    total: i64,
    completed: i64,
    cancelled: i64,
    active: i64,
    completed_today: i64,
    gmv: Decimal,
    commission: Decimal,
    accident_fund: Decimal,
    driver_payout: Decimal,
}

async fn overview(State(st): State<AppState>, _staff: StaffUser) -> AppResult<Json<Value>> {
    // Trip funnel + gross merchandise value from the trips table.
    let t: TripAgg = sqlx::query_as(
        "SELECT \
           count(*) AS total, \
           count(*) FILTER (WHERE status = 'completed') AS completed, \
           count(*) FILTER (WHERE status = 'cancelled') AS cancelled, \
           count(*) FILTER (WHERE status IN ('accepted','arriving','in_progress')) AS active, \
           count(*) FILTER (WHERE status = 'completed' AND created_at::date = current_date) AS completed_today, \
           coalesce(sum(gross_fare) FILTER (WHERE status = 'completed'), 0) AS gmv, \
           coalesce(sum(commission)  FILTER (WHERE status = 'completed'), 0) AS commission, \
           coalesce(sum(accident_fund) FILTER (WHERE status = 'completed'), 0) AS accident_fund, \
           coalesce(sum(driver_payout) FILTER (WHERE status = 'completed'), 0) AS driver_payout \
         FROM trips",
    )
    .fetch_one(&st.db)
    .await?;

    // Supply: driver population + who is online right now.
    let (drivers_total, drivers_approved, drivers_online): (i64, i64, i64) = sqlx::query_as(
        "SELECT count(*), \
                count(*) FILTER (WHERE kyc_status = 'approved'), \
                count(*) FILTER (WHERE is_online = true) \
         FROM drivers",
    )
    .fetch_one(&st.db)
    .await?;

    // Demand: user population + fresh signups.
    let (users_total, riders, signups_7d): (i64, i64, i64) = sqlx::query_as(
        "SELECT count(*), \
                count(*) FILTER (WHERE role = 'rider'), \
                count(*) FILTER (WHERE created_at > now() - interval '7 days') \
         FROM users",
    )
    .fetch_one(&st.db)
    .await?;

    let completion_rate = if t.total > 0 {
        (t.completed as f64) / (t.total as f64)
    } else {
        0.0
    };
    let cancellation_rate = if t.total > 0 {
        (t.cancelled as f64) / (t.total as f64)
    } else {
        0.0
    };

    Ok(Json(json!({
        "trips": {
            "total": t.total,
            "completed": t.completed,
            "cancelled": t.cancelled,
            "active": t.active,
            "completed_today": t.completed_today,
            "completion_rate": completion_rate,
            "cancellation_rate": cancellation_rate,
        },
        "money": {
            "gmv": t.gmv,
            "commission_earned": t.commission,
            "accident_fund_levied": t.accident_fund,
            "driver_payouts": t.driver_payout,
            "currency": "NPR",
        },
        "supply": {
            "drivers_total": drivers_total,
            "drivers_approved": drivers_approved,
            "drivers_online": drivers_online,
        },
        "demand": {
            "users_total": users_total,
            "riders": riders,
            "signups_7d": signups_7d,
        },
    })))
}

#[derive(Deserialize)]
struct RangeQuery {
    days: Option<i64>,
}

async fn timeseries(
    State(st): State<AppState>,
    _staff: StaffUser,
    Query(q): Query<RangeQuery>,
) -> AppResult<Json<Value>> {
    let days = q.days.unwrap_or(14).clamp(1, 90);
    // Trips per day (requested vs completed) over the window, gap-filled.
    let rows: Vec<(chrono::NaiveDate, i64, i64, Decimal)> = sqlx::query_as(
        "SELECT d::date AS day, \
                count(t.id) AS requested, \
                count(t.id) FILTER (WHERE t.status = 'completed') AS completed, \
                coalesce(sum(t.gross_fare) FILTER (WHERE t.status = 'completed'), 0) AS gmv \
         FROM generate_series(current_date - ($1::int - 1), current_date, interval '1 day') d \
         LEFT JOIN trips t ON t.created_at::date = d::date \
         GROUP BY day ORDER BY day",
    )
    .bind(days as i32)
    .fetch_all(&st.db)
    .await?;

    let series: Vec<Value> = rows
        .into_iter()
        .map(|(day, requested, completed, gmv)| {
            json!({ "day": day, "requested": requested, "completed": completed, "gmv": gmv })
        })
        .collect();
    Ok(Json(json!({ "days": days, "series": series })))
}
