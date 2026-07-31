//! Rider (and shared "me") endpoints: profile, saved locations, location pings.

use crate::error::AppResult;
use crate::models::{SavedLocation, User};
use crate::state::{AppState, AuthUser};
use axum::extract::{Path, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/me", get(me).put(update_me))
        .route("/v1/me/locations", get(list_locations).post(add_location))
        .route(
            "/v1/me/locations/{id}",
            axum::routing::delete(delete_location),
        )
        .route("/v1/me/location-ping", post(location_ping))
}

async fn me(State(st): State<AppState>, AuthUser(claims): AuthUser) -> AppResult<Json<User>> {
    let user: User = sqlx::query_as(
        "SELECT id, phone, full_name, role, status, created_at, updated_at FROM users WHERE id = $1",
    )
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(user))
}

#[derive(Deserialize)]
struct UpdateMe {
    full_name: Option<String>,
}

async fn update_me(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<UpdateMe>,
) -> AppResult<Json<User>> {
    let user: User = sqlx::query_as(
        "UPDATE users SET full_name = COALESCE($2, full_name) WHERE id = $1 \
         RETURNING id, phone, full_name, role, status, created_at, updated_at",
    )
    .bind(claims.sub)
    .bind(body.full_name)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(user))
}

async fn list_locations(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Vec<SavedLocation>>> {
    let rows: Vec<SavedLocation> = sqlx::query_as(
        "SELECT id, user_id, label, address, lat, lng, created_at FROM saved_locations \
         WHERE user_id = $1 ORDER BY created_at DESC",
    )
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
struct AddLocation {
    label: String,
    address: Option<String>,
    lat: f64,
    lng: f64,
}

async fn add_location(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<AddLocation>,
) -> AppResult<Json<SavedLocation>> {
    let row: SavedLocation = sqlx::query_as(
        "INSERT INTO saved_locations (user_id, label, address, lat, lng) VALUES ($1, $2, $3, $4, $5) \
         RETURNING id, user_id, label, address, lat, lng, created_at",
    )
    .bind(claims.sub)
    .bind(body.label)
    .bind(body.address)
    .bind(body.lat)
    .bind(body.lng)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(row))
}

async fn delete_location(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    sqlx::query("DELETE FROM saved_locations WHERE id = $1 AND user_id = $2")
        .bind(id)
        .bind(claims.sub)
        .execute(&st.db)
        .await?;
    Ok(Json(json!({ "ok": true })))
}

#[derive(Deserialize)]
struct LocationPing {
    lat: f64,
    lng: f64,
    accuracy_m: Option<f64>,
    heading_deg: Option<f64>,
    speed_mps: Option<f64>,
}

/// Record a live position for the authenticated user (rider or driver). Feeds
/// the dispatch geo-index and the ops live-tracking console.
async fn location_ping(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<LocationPing>,
) -> AppResult<Json<Value>> {
    sqlx::query(
        "INSERT INTO location_pings (user_id, lat, lng, accuracy_m, heading_deg, speed_mps) \
         VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(claims.sub)
    .bind(body.lat)
    .bind(body.lng)
    .bind(body.accuracy_m)
    .bind(body.heading_deg)
    .bind(body.speed_mps)
    .execute(&st.db)
    .await?;
    Ok(Json(json!({ "ok": true })))
}
