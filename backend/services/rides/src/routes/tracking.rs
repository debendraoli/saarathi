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
        .route("/v1/admin/trips/{id}/route", get(trip_route))
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

/// How close (in km) a driver's live position needs to be to the
/// destination before a plain ride is auto-completed — generous enough to
/// tolerate ordinary GPS drift (~15-30m in the open, worse downtown).
const ARRIVAL_RADIUS_KM: f64 = 0.06;

/// Auto-completes a plain `ride` the moment the driver's own position ping
/// lands within [ARRIVAL_RADIUS_KM] of the destination — so a driver never
/// has to remember to tap "Complete trip." Deliberately scoped to
/// `trip_type = 'ride'` only: a parcel-send needs proof-of-delivery, and a
/// marketplace courier leg completes via the order's own status sync
/// (`update_status`) — neither should be geofence-completed here. Silently
/// a no-op once the trip leaves `in_progress` (including once this itself
/// completes it), so it can't double-fire on later pings.
async fn maybe_auto_complete(st: &AppState, trip_id: Uuid, driver_id: Uuid, lat: f64, lng: f64) {
    let row: Option<(String, String, f64, f64)> = sqlx::query_as(
        "SELECT trip_type::text, status::text, dest_lat, dest_lng \
         FROM trips WHERE id = $1 AND driver_id = $2",
    )
    .bind(trip_id)
    .bind(driver_id)
    .fetch_optional(&st.db)
    .await
    .ok()
    .flatten();
    let Some((trip_type, status, dest_lat, dest_lng)) = row else {
        return;
    };
    if trip_type != "ride" || status != "in_progress" {
        return;
    }
    let dist = saarathi_core::routing::haversine_km(
        saarathi_core::routing::LatLng { lat, lng },
        saarathi_core::routing::LatLng {
            lat: dest_lat,
            lng: dest_lng,
        },
    );
    if dist > ARRIVAL_RADIUS_KM {
        return;
    }
    if let Err(e) = crate::routes::rides::complete_trip(st, trip_id, driver_id).await {
        tracing::warn!(trip = %trip_id, error = %e, "auto-complete on arrival failed");
    } else {
        tracing::info!(trip = %trip_id, "auto-completed: driver reached destination");
    }
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
    maybe_auto_complete(&st, id, claims.sub, b.lat, b.lng).await;
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

#[derive(Serialize)]
struct BreadcrumbPoint {
    lat: f64,
    lng: f64,
    at: chrono::DateTime<chrono::Utc>,
}

#[derive(Serialize)]
struct TripRoute {
    trip_id: Uuid,
    status: String,
    origin_lat: f64,
    origin_lng: f64,
    dest_lat: f64,
    dest_lng: f64,
    breadcrumbs: Vec<BreadcrumbPoint>,
}

/// Start-to-end path reconstruction for ops review — the "God View" trail.
/// Breadcrumbs come from `trip_events` (every location ping posted during the
/// trip, kind='location'), which is an append-only durable log unlike the
/// Redis "latest position" used for live tracking — it's the only place a
/// *completed* trip's path still exists.
async fn trip_route(
    State(st): State<AppState>,
    _staff: StaffUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<TripRoute>> {
    let trip: Option<(String, f64, f64, f64, f64)> = sqlx::query_as(
        "SELECT status::text, origin_lat, origin_lng, dest_lat, dest_lng \
         FROM trips WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(&st.db)
    .await?;
    let (status, origin_lat, origin_lng, dest_lat, dest_lng) = trip.ok_or(AppError::NotFound)?;

    let events: Vec<(Value, chrono::DateTime<chrono::Utc>)> = sqlx::query_as(
        "SELECT payload, created_at FROM trip_events \
         WHERE trip_id = $1 AND kind = 'location' ORDER BY created_at ASC",
    )
    .bind(id)
    .fetch_all(&st.db)
    .await?;
    let breadcrumbs = events
        .into_iter()
        .filter_map(|(payload, at)| {
            let lat = payload.get("lat")?.as_f64()?;
            let lng = payload.get("lng")?.as_f64()?;
            Some(BreadcrumbPoint { lat, lng, at })
        })
        .collect();

    Ok(Json(TripRoute {
        trip_id: id,
        status,
        origin_lat,
        origin_lng,
        dest_lat,
        dest_lng,
        breadcrumbs,
    }))
}
