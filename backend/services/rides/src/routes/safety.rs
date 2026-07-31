//! Emergency / SOS (E6). A rider or driver raises an alert during a trip; it's
//! logged (audit-grade), broadcast to the trip channel, and surfaced to Ops.
//! (Vehicle QR verification is deferred; payment is direct-to-platform.)

use crate::auth::{AuthUser, StaffUser};
use crate::error::{AppError, AppResult};
use crate::notify;
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
        .route("/v1/rides/{id}/sos", post(trigger))
        .route("/v1/admin/sos", get(list_active))
        .route("/v1/admin/sos/{id}/resolve", post(resolve))
}

#[derive(Deserialize)]
struct SosRequest {
    lat: Option<f64>,
    lng: Option<f64>,
    note: Option<String>,
}

#[derive(Serialize, sqlx::FromRow)]
struct SosIncident {
    id: Uuid,
    user_id: Uuid,
    trip_id: Option<Uuid>,
    lat: Option<f64>,
    lng: Option<f64>,
    channel: String,
    status: String,
    note: Option<String>,
    created_at: DateTime<Utc>,
}

async fn trigger(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
    Json(b): Json<SosRequest>,
) -> AppResult<Json<SosIncident>> {
    let row: Option<(Uuid, Option<Uuid>)> =
        sqlx::query_as("SELECT rider_id, driver_id FROM trips WHERE id = $1")
            .bind(id)
            .fetch_optional(&st.db)
            .await?;
    let (rider, driver) = row.ok_or(AppError::NotFound)?;
    if rider != claims.sub && driver != Some(claims.sub) {
        return Err(AppError::Forbidden);
    }

    let incident: SosIncident = sqlx::query_as(
        "INSERT INTO sos_incidents (user_id, trip_id, lat, lng, note) VALUES ($1, $2, $3, $4, $5) \
         RETURNING id, user_id, trip_id, lat, lng, channel, status, note, created_at",
    )
    .bind(claims.sub)
    .bind(id)
    .bind(b.lat)
    .bind(b.lng)
    .bind(b.note)
    .fetch_one(&st.db)
    .await?;

    // Alert the trip channel + notify the counterpart. Ops watch the SOS console.
    st.hub.publish(
        id,
        json!({ "type": "sos", "incident_id": incident.id, "user_id": claims.sub, "lat": b.lat, "lng": b.lng })
            .to_string(),
    );
    let counterpart = if rider == claims.sub {
        driver
    } else {
        Some(rider)
    };
    if let Some(other) = counterpart {
        let _ = notify::send(
            &st.db,
            other,
            "safety",
            "SOS raised on your trip",
            "Emergency alert — Ops has been notified.",
        )
        .await;
    }
    tracing::warn!(incident = %incident.id, trip = %id, "SOS — OPS ALERT");
    Ok(Json(incident))
}

async fn list_active(
    State(st): State<AppState>,
    _staff: StaffUser,
) -> AppResult<Json<Vec<SosIncident>>> {
    let rows: Vec<SosIncident> = sqlx::query_as(
        "SELECT id, user_id, trip_id, lat, lng, channel, status, note, created_at \
         FROM sos_incidents WHERE status = 'active' ORDER BY created_at DESC",
    )
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
struct ResolveRequest {
    note: Option<String>,
}

async fn resolve(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Path(id): Path<Uuid>,
    Json(b): Json<ResolveRequest>,
) -> AppResult<Json<Value>> {
    let res = sqlx::query(
        "UPDATE sos_incidents SET status = 'resolved', resolved_by = $2, resolved_at = now(), \
         note = COALESCE($3, note) WHERE id = $1 AND status = 'active'",
    )
    .bind(id)
    .bind(claims.sub)
    .bind(b.note)
    .execute(&st.db)
    .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(Json(json!({ "resolved": true })))
}
