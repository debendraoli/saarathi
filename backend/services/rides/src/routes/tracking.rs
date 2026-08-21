//! Live tracking (the "where's my driver" flow): the driver/rider posts position
//! during an active trip; the counterpart reads the latest (WS push + REST poll).
//! Positions live in Redis with a short TTL — hot, ephemeral, cheap.

use crate::auth::{AuthUser, StaffUser};
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/v1/rides/{id}/location",
            post(post_location).get(get_location),
        )
        .route("/v1/admin/trips/active", get(active_trips))
}

fn redis_err(e: redis::RedisError) -> AppError {
    AppError::Other(anyhow::Error::new(e))
}

async fn assert_participant(
    st: &AppState,
    trip_id: Uuid,
    claims: &crate::auth::Claims,
) -> AppResult<()> {
    let row: Option<(Uuid, Option<Uuid>)> =
        sqlx::query_as("SELECT rider_id, driver_id FROM trips WHERE id = $1")
            .bind(trip_id)
            .fetch_optional(&st.db)
            .await?;
    let (rider, driver) = row.ok_or(AppError::NotFound)?;
    if rider != claims.sub && driver != Some(claims.sub) && !claims.is_staff() {
        return Err(AppError::Forbidden);
    }
    Ok(())
}

#[derive(Deserialize)]
struct Location {
    lat: f64,
    lng: f64,
    heading: Option<f64>,
    speed: Option<f64>,
}

async fn post_location(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
    Json(b): Json<Location>,
) -> AppResult<Json<Value>> {
    assert_participant(&st, id, &claims).await?;
    let mut r = st.redis.clone();
    let key = format!("trip:{id}:loc");
    let _: () = redis::cmd("HSET")
        .arg(&key)
        .arg("lat")
        .arg(b.lat)
        .arg("lng")
        .arg(b.lng)
        .arg("heading")
        .arg(b.heading.unwrap_or(0.0))
        .arg("speed")
        .arg(b.speed.unwrap_or(0.0))
        .arg("at")
        .arg(chrono::Utc::now().timestamp())
        .arg("by")
        .arg(claims.sub.to_string())
        .query_async(&mut r)
        .await
        .map_err(redis_err)?;
    let _: () = redis::cmd("EXPIRE")
        .arg(&key)
        .arg(300)
        .query_async(&mut r)
        .await
        .map_err(redis_err)?;

    let payload = json!({ "type": "location", "lat": b.lat, "lng": b.lng, "heading": b.heading, "speed": b.speed, "by": claims.sub });
    // Best-effort breadcrumb persistence (mirrors ws.rs), so the REST posting
    // path leaves the same durable trip_events trail as the WebSocket path.
    let _ = sqlx::query(
        "INSERT INTO trip_events (trip_id, sender_id, kind, payload) VALUES ($1, $2, 'location', $3)",
    )
    .bind(id)
    .bind(claims.sub)
    .bind(&payload)
    .execute(&st.db)
    .await;

    st.hub.publish(id, payload.to_string());
    Ok(Json(json!({ "ok": true })))
}

async fn get_location(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    assert_participant(&st, id, &claims).await?;
    let mut r = st.redis.clone();
    let key = format!("trip:{id}:loc");
    let map: HashMap<String, String> = redis::cmd("HGETALL")
        .arg(&key)
        .query_async(&mut r)
        .await
        .map_err(redis_err)?;
    if map.is_empty() {
        return Err(AppError::NotFound);
    }
    let f = |k: &str| map.get(k).and_then(|v| v.parse::<f64>().ok());
    Ok(Json(json!({
        "lat": f("lat"),
        "lng": f("lng"),
        "heading": f("heading"),
        "speed": f("speed"),
        "at": map.get("at").and_then(|v| v.parse::<i64>().ok()),
        "by": map.get("by"),
    })))
}

#[derive(Serialize, sqlx::FromRow)]
struct ActiveTrip {
    id: Uuid,
    rider_id: Uuid,
    driver_id: Option<Uuid>,
    status: String,
    origin_lat: f64,
    origin_lng: f64,
    dest_lat: f64,
    dest_lng: f64,
    final_fare: rust_decimal::Decimal,
}

async fn active_trips(
    State(st): State<AppState>,
    _staff: StaffUser,
) -> AppResult<Json<Vec<ActiveTrip>>> {
    let rows: Vec<ActiveTrip> = sqlx::query_as(
        "SELECT id, rider_id, driver_id, status::text AS status, origin_lat, origin_lng, \
                dest_lat, dest_lng, final_fare \
         FROM trips WHERE status IN ('accepted','arriving','in_progress') \
         ORDER BY updated_at DESC LIMIT 200",
    )
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}
