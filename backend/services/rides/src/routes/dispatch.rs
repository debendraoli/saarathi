//! Dispatch-facing endpoints: driver presence, job offers, and ops override.

use crate::auth::{AuthUser, StaffUser};
use crate::dispatch;
use crate::error::{AppError, AppResult};
use crate::models::{Trip, TRIP_COLS};
use crate::state::AppState;
use axum::extract::{Path, Query, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use saarathi_core::api::ErrorCode;
use saarathi_core::domain::roles;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/driver/online", post(go_online))
        .route("/v1/driver/heartbeat", post(heartbeat))
        .route("/v1/driver/offline", post(go_offline))
        .route("/v1/driver/offers", get(my_offers))
        .route("/v1/rides/nearby-drivers", get(nearby_drivers))
        .route("/v1/rides/{id}/offer/accept", post(accept_offer))
        .route("/v1/rides/{id}/offer/decline", post(decline_offer))
        .route("/v1/admin/rides/{id}/assign", post(ops_assign))
}

#[derive(Deserialize)]
pub(crate) struct OnlineRequest {
    pub(crate) lat: f64,
    pub(crate) lng: f64,
    #[serde(default)]
    pub(crate) job_types: Vec<String>,
}

/// Everything `go_online` actually does, factored out so the new
/// driver-scoped WebSocket (`driver_ws.rs`) — connected for as long as the
/// driver app considers itself online, independent of any specific trip —
/// can accept an `online` frame and perform the exact same transition,
/// rather than only ever being reachable over HTTP.
pub(crate) async fn do_go_online(
    st: &AppState,
    claims: &crate::auth::Claims,
    body: OnlineRequest,
) -> AppResult<Vec<String>> {
    if claims.role != roles::DRIVER {
        return Err(AppError::Forbidden);
    }
    // Only KYC-approved drivers may go online.
    let kyc: Option<(String,)> =
        sqlx::query_as("SELECT kyc_status::text FROM drivers WHERE user_id = $1")
            .bind(claims.sub)
            .fetch_optional(&st.db)
            .await?;
    if kyc.map(|k| k.0) != Some("approved".to_string()) {
        return Err(AppError::Forbidden);
    }
    let job_types = if body.job_types.is_empty() {
        vec!["ride".to_string()]
    } else {
        body.job_types
    };
    dispatch::set_online(st, claims.sub, body.lat, body.lng, &job_types)
        .await
        .map_err(AppError::Other)?;
    // Persist the availability toggle so the dashboard sees who is online and it
    // survives a Redis flush.
    if let Err(e) = sqlx::query(
        "UPDATE drivers SET is_online = true, last_online_at = now() WHERE user_id = $1",
    )
    .bind(claims.sub)
    .execute(&st.db)
    .await
    {
        tracing::warn!(driver = %claims.sub, error = %e, "is_online=true persistence failed");
    }
    Ok(job_types)
}

async fn go_online(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<OnlineRequest>,
) -> AppResult<Json<Value>> {
    let job_types = do_go_online(&st, &claims, body).await?;
    Ok(Json(json!({ "online": true, "job_types": job_types })))
}

#[derive(Deserialize)]
pub(crate) struct HeartbeatRequest {
    pub(crate) lat: f64,
    pub(crate) lng: f64,
    #[serde(default)]
    pub(crate) job_types: Vec<String>,
}

pub(crate) async fn do_heartbeat(
    st: &AppState,
    claims: &crate::auth::Claims,
    body: HeartbeatRequest,
) -> AppResult<()> {
    if claims.role != roles::DRIVER {
        return Err(AppError::Forbidden);
    }
    let job_types = if body.job_types.is_empty() {
        vec!["ride".to_string()]
    } else {
        body.job_types
    };
    dispatch::set_online(st, claims.sub, body.lat, body.lng, &job_types)
        .await
        .map_err(AppError::Other)?;
    Ok(())
}

async fn heartbeat(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<HeartbeatRequest>,
) -> AppResult<Json<Value>> {
    do_heartbeat(&st, &claims, body).await?;
    Ok(Json(json!({ "ok": true })))
}

pub(crate) async fn do_go_offline(st: &AppState, claims: &crate::auth::Claims) -> AppResult<()> {
    dispatch::set_offline(st, claims.sub)
        .await
        .map_err(AppError::Other)?;
    if let Err(e) = sqlx::query("UPDATE drivers SET is_online = false WHERE user_id = $1")
        .bind(claims.sub)
        .execute(&st.db)
        .await
    {
        tracing::warn!(driver = %claims.sub, error = %e, "is_online=false persistence failed");
    }
    Ok(())
}

async fn go_offline(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Value>> {
    do_go_offline(&st, &claims).await?;
    Ok(Json(json!({ "online": false })))
}

#[derive(Serialize, sqlx::FromRow)]
struct OfferView {
    trip_id: Uuid,
    expires_at: DateTime<Utc>,
    origin_lat: f64,
    origin_lng: f64,
    dest_lat: f64,
    dest_lng: f64,
    gross_fare: rust_decimal::Decimal,
    final_fare: rust_decimal::Decimal,
    vehicle_class: String,
    distance_km: rust_decimal::Decimal,
    /// 'instant' (algorithmic fare, shown above) or 'bid' (the driver should
    /// bid against `ask_fare` instead — see `routes::bidding`).
    pricing_mode: String,
    ask_fare: Option<rust_decimal::Decimal>,
}

async fn my_offers(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Vec<OfferView>>> {
    let offers: Vec<OfferView> = sqlx::query_as(
        "SELECT o.trip_id, o.expires_at, t.origin_lat, t.origin_lng, t.dest_lat, t.dest_lng, \
                t.gross_fare, t.final_fare, t.vehicle_class, t.distance_km, \
                t.pricing_mode, t.ask_fare \
         FROM trip_offers o JOIN trips t ON t.id = o.trip_id \
         WHERE o.driver_id = $1 AND o.status = 'offered' AND o.expires_at > now() \
         ORDER BY o.created_at",
    )
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(offers))
}

#[derive(Deserialize)]
struct NearbyDriversQuery {
    lat: f64,
    lng: f64,
    #[serde(default)]
    radius_km: Option<f64>,
}

#[derive(Serialize)]
struct NearbyDriverPoint {
    lat: f64,
    lng: f64,
}

/// Approximate nearby-driver positions for the rider-facing "searching" map
/// animation — any authed user, not just the trip's own rider, since this is
/// purely cosmetic (points are jittered, see `dispatch::nearby_positions`)
/// and doesn't need to be scoped to a specific trip.
async fn nearby_drivers(
    State(st): State<AppState>,
    AuthUser(_claims): AuthUser,
    Query(q): Query<NearbyDriversQuery>,
) -> AppResult<Json<Vec<NearbyDriverPoint>>> {
    let radius_km = q.radius_km.unwrap_or(3.0).clamp(0.5, 5.0);
    let points = dispatch::nearby_positions(&st, q.lng, q.lat, radius_km).await?;
    Ok(Json(
        points
            .into_iter()
            .map(|(lat, lng)| NearbyDriverPoint { lat, lng })
            .collect(),
    ))
}

/// Accept-then-cancel trips (by this driver) allowed in the trailing window
/// before new offers are blocked. A trip only reaches `cancelled_by_role =
/// 'driver'` once the driver has actually accepted (driver_id is only set on
/// acceptance), so this is inherently a cancel-*after*-accept count, not
/// declined offers (which never touch `trips` at all).
const MAX_DRIVER_CANCELS_PER_WINDOW: i64 = 3;
const DRIVER_CANCEL_WINDOW_HOURS: i64 = 24;

async fn accept_offer(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Trip>> {
    // A driver needs a positive credit balance to accept jobs — cash trips draw
    // the platform's cut from it on completion (doc 13 §4.1); zero/negative
    // means top up first rather than accruing an uncollectable debt.
    let credit_balance = crate::payments::driver_credit_balance(&st.db, claims.sub).await?;
    if credit_balance <= rust_decimal::Decimal::ZERO {
        return Err(AppError::bad(
            ErrorCode::InsufficientDriverCredits,
            "top up your credit balance to accept rides",
        ));
    }

    let recent_cancels: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM trips \
         WHERE driver_id = $1 AND status = 'cancelled' AND cancelled_by_role = 'driver' \
           AND cancelled_at > now() - make_interval(hours => $2)",
    )
    .bind(claims.sub)
    .bind(DRIVER_CANCEL_WINDOW_HOURS as i32)
    .fetch_one(&st.db)
    .await?;
    if recent_cancels >= MAX_DRIVER_CANCELS_PER_WINDOW {
        return Err(AppError::bad(
            ErrorCode::TooManyCancellations,
            format!(
                "too many cancelled trips in the last {DRIVER_CANCEL_WINDOW_HOURS}h — try again later"
            ),
        ));
    }

    let mut tx = st.db.begin().await?;

    // One active trip per driver at a time — nothing upstream stops the same
    // driver being offered two different trips in the sequential-offer race
    // window, so this is the actual point of enforcement.
    let already_active: Option<Uuid> = sqlx::query_scalar(
        "SELECT id FROM trips WHERE driver_id = $1 \
         AND status IN ('accepted', 'arriving', 'in_progress') LIMIT 1",
    )
    .bind(claims.sub)
    .fetch_optional(&mut *tx)
    .await?;
    if let Some(other_trip) = already_active {
        return Err(AppError::conflict(
            ErrorCode::Conflict,
            format!("you already have an active trip ({other_trip}) — complete it first"),
        ));
    }

    let offer: Option<(Uuid,)> = sqlx::query_as(
        "SELECT id FROM trip_offers \
         WHERE trip_id = $1 AND driver_id = $2 AND status = 'offered' AND expires_at > now() \
         FOR UPDATE",
    )
    .bind(id)
    .bind(claims.sub)
    .fetch_optional(&mut *tx)
    .await?;
    let Some((offer_id,)) = offer else {
        return Err(AppError::conflict(
            ErrorCode::OfferExpired,
            "offer expired or not found",
        ));
    };

    let trip: Option<Trip> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "UPDATE trips SET driver_id = $2, status = 'accepted', accepted_at = now(), updated_at = now() \
         WHERE id = $1 AND status = 'requested' RETURNING {TRIP_COLS}"
    )))
    .bind(id)
    .bind(claims.sub)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|e| match e {
        // trips_driver_one_active_idx backstop: lost the race against another
        // accept for this driver that committed first.
        sqlx::Error::Database(db) if db.is_unique_violation() => AppError::conflict(
            ErrorCode::Conflict,
            "you already have an active trip — complete it first",
        ),
        other => AppError::Db(other),
    })?;
    let Some(trip) = trip else {
        return Err(AppError::conflict(
            ErrorCode::TripUnavailable,
            "trip is no longer available",
        ));
    };

    sqlx::query("UPDATE trip_offers SET status = 'accepted' WHERE id = $1")
        .bind(offer_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        "UPDATE trip_offers SET status = 'expired' WHERE trip_id = $1 AND status = 'offered' AND id <> $2",
    )
    .bind(id)
    .bind(offer_id)
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    st.hub.publish(
        id,
        json!({ "type": "status", "status": "accepted", "driver_id": claims.sub }).to_string(),
    );
    crate::notify::send(
        &st.nats,
        trip.rider_id,
        saarathi_core::domain::notif::TRANSACTIONAL,
        "Driver on the way",
        "Your driver accepted the trip and is heading to your pickup.",
        Some(format!("saarathi://trip/{id}")),
    )
    .await;
    Ok(Json(trip))
}

async fn decline_offer(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    sqlx::query(
        "UPDATE trip_offers SET status = 'declined' \
         WHERE trip_id = $1 AND driver_id = $2 AND status = 'offered'",
    )
    .bind(id)
    .bind(claims.sub)
    .execute(&st.db)
    .await?;
    // Immediately try the next-nearest driver.
    if let Err(e) = dispatch::dispatch_trip(&st, id).await {
        tracing::warn!(trip = %id, error = %e, "redispatch after decline_offer failed");
    }
    Ok(Json(json!({ "declined": true })))
}

#[derive(Deserialize)]
struct AssignRequest {
    driver_id: Uuid,
}

async fn ops_assign(
    State(st): State<AppState>,
    _staff: StaffUser,
    Path(id): Path<Uuid>,
    Json(body): Json<AssignRequest>,
) -> AppResult<Json<Trip>> {
    let trip: Option<Trip> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "UPDATE trips SET driver_id = $2, status = 'accepted', accepted_at = now(), updated_at = now() \
         WHERE id = $1 AND status = 'requested' RETURNING {TRIP_COLS}"
    )))
    .bind(id)
    .bind(body.driver_id)
    .fetch_optional(&st.db)
    .await?;
    let trip = trip.ok_or_else(|| {
        AppError::conflict(ErrorCode::TripUnavailable, "trip is no longer available")
    })?;

    sqlx::query(
        "UPDATE trip_offers SET status = 'expired' WHERE trip_id = $1 AND status = 'offered'",
    )
    .bind(id)
    .execute(&st.db)
    .await?;
    st.hub.publish(
        id,
        json!({ "type": "status", "status": "accepted", "driver_id": body.driver_id, "by": "ops" })
            .to_string(),
    );
    Ok(Json(trip))
}
