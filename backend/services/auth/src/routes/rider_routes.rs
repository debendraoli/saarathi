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
        .route(
            "/v1/me/preferences",
            get(get_preferences).put(update_preferences),
        )
        .route(
            "/v1/me/recent-searches",
            get(list_recent).post(add_recent).delete(clear_recent),
        )
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

// ── Preferences (default payment method + appearance) ───────────────────────

#[derive(serde::Serialize, sqlx::FromRow)]
struct Preferences {
    default_payment_method: String,
    theme: String,
}

async fn get_preferences(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Preferences>> {
    let prefs: Preferences = sqlx::query_as(
        "SELECT default_payment_method, theme FROM user_preferences WHERE user_id = $1",
    )
    .bind(claims.sub)
    .fetch_optional(&st.db)
    .await?
    .unwrap_or(Preferences {
        default_payment_method: "cash".into(),
        theme: "system".into(),
    });
    Ok(Json(prefs))
}

#[derive(Deserialize)]
struct UpdatePreferences {
    default_payment_method: Option<String>,
    theme: Option<String>,
}

async fn update_preferences(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<UpdatePreferences>,
) -> AppResult<Json<Preferences>> {
    if let Some(m) = &body.default_payment_method {
        if m != "cash" && m != "wallet" {
            return Err(crate::error::AppError::BadRequest(
                "payment method must be 'cash' or 'wallet'".into(),
            ));
        }
    }
    if let Some(t) = &body.theme {
        if !matches!(t.as_str(), "system" | "light" | "dark") {
            return Err(crate::error::AppError::BadRequest(
                "theme must be system|light|dark".into(),
            ));
        }
    }
    let prefs: Preferences = sqlx::query_as(
        "INSERT INTO user_preferences (user_id, default_payment_method, theme, updated_at) \
         VALUES ($1, COALESCE($2, 'cash'), COALESCE($3, 'system'), now()) \
         ON CONFLICT (user_id) DO UPDATE SET \
             default_payment_method = COALESCE($2, user_preferences.default_payment_method), \
             theme = COALESCE($3, user_preferences.theme), updated_at = now() \
         RETURNING default_payment_method, theme",
    )
    .bind(claims.sub)
    .bind(body.default_payment_method)
    .bind(body.theme)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(prefs))
}

// ── Recent searches (synced across the rider's devices) ─────────────────────

#[derive(serde::Serialize, sqlx::FromRow)]
struct RecentSearch {
    id: Uuid,
    label: String,
    address: Option<String>,
    lat: Option<f64>,
    lng: Option<f64>,
}

async fn list_recent(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Vec<RecentSearch>>> {
    let rows: Vec<RecentSearch> = sqlx::query_as(
        "SELECT id, label, address, lat, lng FROM recent_searches \
         WHERE user_id = $1 ORDER BY created_at DESC LIMIT 10",
    )
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
struct AddRecent {
    label: String,
    address: Option<String>,
    lat: Option<f64>,
    lng: Option<f64>,
}

async fn add_recent(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<AddRecent>,
) -> AppResult<Json<Value>> {
    // De-dupe by label, then trim the list back to the 10 most recent.
    sqlx::query("DELETE FROM recent_searches WHERE user_id = $1 AND label = $2")
        .bind(claims.sub)
        .bind(&body.label)
        .execute(&st.db)
        .await?;
    sqlx::query(
        "INSERT INTO recent_searches (user_id, label, address, lat, lng) VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(claims.sub)
    .bind(&body.label)
    .bind(body.address)
    .bind(body.lat)
    .bind(body.lng)
    .execute(&st.db)
    .await?;
    sqlx::query(
        "DELETE FROM recent_searches WHERE user_id = $1 AND id NOT IN ( \
            SELECT id FROM recent_searches WHERE user_id = $1 ORDER BY created_at DESC LIMIT 10)",
    )
    .bind(claims.sub)
    .execute(&st.db)
    .await?;
    Ok(Json(json!({ "ok": true })))
}

async fn clear_recent(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Value>> {
    sqlx::query("DELETE FROM recent_searches WHERE user_id = $1")
        .bind(claims.sub)
        .execute(&st.db)
        .await?;
    Ok(Json(json!({ "ok": true })))
}
