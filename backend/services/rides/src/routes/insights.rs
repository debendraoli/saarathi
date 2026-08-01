//! Ops insights: ride history (with ratings, status, cancellations), the
//! complaints/cancellations feed, and filterable leaderboards (top earners,
//! best rated, most cancellations). All staff-gated, read-only.

use crate::auth::StaffUser;
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::extract::{Query, State};
use axum::{routing::get, Json, Router};
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/admin/rides", get(rides))
        .route("/v1/admin/cancellations", get(cancellations))
        .route("/v1/admin/leaderboard", get(leaderboard))
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
                rt.stars AS driver_stars, t.created_at \
         FROM trips t \
         JOIN users ur ON ur.id = t.rider_id \
         LEFT JOIN users ud ON ud.id = t.driver_id \
         LEFT JOIN ratings rt ON rt.trip_id = t.id AND rt.role = 'rider_rates_driver' ";

    let rows: Vec<RideRow> = match q.status.as_deref() {
        Some(s) if !s.is_empty() => {
            sqlx::query_as(&format!(
                "{base} WHERE t.status::text = $1 ORDER BY t.created_at DESC LIMIT 200"
            ))
            .bind(s)
            .fetch_all(&st.db)
            .await?
        }
        _ => {
            sqlx::query_as(&format!("{base} ORDER BY t.created_at DESC LIMIT 200"))
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
                NULL::int AS driver_stars, t.created_at \
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
