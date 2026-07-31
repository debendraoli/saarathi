//! Dispatch-facing endpoints: driver presence, job offers, and ops override.

use crate::auth::{AuthUser, StaffUser};
use crate::dispatch;
use crate::error::{AppError, AppResult};
use crate::models::{Trip, TRIP_COLS};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/driver/online", post(go_online))
        .route("/v1/driver/heartbeat", post(heartbeat))
        .route("/v1/driver/offline", post(go_offline))
        .route("/v1/driver/offers", get(my_offers))
        .route("/v1/rides/{id}/offer/accept", post(accept_offer))
        .route("/v1/rides/{id}/offer/decline", post(decline_offer))
        .route("/v1/admin/rides/{id}/assign", post(ops_assign))
}

#[derive(Deserialize)]
struct OnlineRequest {
    lat: f64,
    lng: f64,
    #[serde(default)]
    job_types: Vec<String>,
}

async fn go_online(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<OnlineRequest>,
) -> AppResult<Json<Value>> {
    if claims.role != "driver" {
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
    dispatch::set_online(&st, claims.sub, body.lat, body.lng, &job_types)
        .await
        .map_err(AppError::Other)?;
    Ok(Json(json!({ "online": true, "job_types": job_types })))
}

#[derive(Deserialize)]
struct HeartbeatRequest {
    lat: f64,
    lng: f64,
    #[serde(default)]
    job_types: Vec<String>,
}

async fn heartbeat(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<HeartbeatRequest>,
) -> AppResult<Json<Value>> {
    if claims.role != "driver" {
        return Err(AppError::Forbidden);
    }
    let job_types = if body.job_types.is_empty() {
        vec!["ride".to_string()]
    } else {
        body.job_types
    };
    dispatch::set_online(&st, claims.sub, body.lat, body.lng, &job_types)
        .await
        .map_err(AppError::Other)?;
    Ok(Json(json!({ "ok": true })))
}

async fn go_offline(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Value>> {
    dispatch::set_offline(&st, claims.sub)
        .await
        .map_err(AppError::Other)?;
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
}

async fn my_offers(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Vec<OfferView>>> {
    let offers: Vec<OfferView> = sqlx::query_as(
        "SELECT o.trip_id, o.expires_at, t.origin_lat, t.origin_lng, t.dest_lat, t.dest_lng, \
                t.gross_fare, t.final_fare, t.vehicle_class \
         FROM trip_offers o JOIN trips t ON t.id = o.trip_id \
         WHERE o.driver_id = $1 AND o.status = 'offered' AND o.expires_at > now() \
         ORDER BY o.created_at",
    )
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(offers))
}

async fn accept_offer(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Trip>> {
    let mut tx = st.db.begin().await?;

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
        return Err(AppError::Conflict("offer expired or not found".into()));
    };

    let trip: Option<Trip> = sqlx::query_as(&format!(
        "UPDATE trips SET driver_id = $2, status = 'accepted', accepted_at = now(), updated_at = now() \
         WHERE id = $1 AND status = 'requested' RETURNING {TRIP_COLS}"
    ))
    .bind(id)
    .bind(claims.sub)
    .fetch_optional(&mut *tx)
    .await?;
    let Some(trip) = trip else {
        return Err(AppError::Conflict("trip is no longer available".into()));
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
    let _ = dispatch::dispatch_trip(&st, id).await;
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
    let trip: Option<Trip> = sqlx::query_as(&format!(
        "UPDATE trips SET driver_id = $2, status = 'accepted', accepted_at = now(), updated_at = now() \
         WHERE id = $1 AND status = 'requested' RETURNING {TRIP_COLS}"
    ))
    .bind(id)
    .bind(body.driver_id)
    .fetch_optional(&st.db)
    .await?;
    let trip = trip.ok_or_else(|| AppError::Conflict("trip is no longer available".into()))?;

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
