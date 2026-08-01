//! Feature-flag management (dashboard circuit breakers) + a public read for apps.

use crate::auth::{AuthUser, StaffUser};
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{
    routing::{get, put},
    Json, Router,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/admin/flags", get(list))
        .route("/v1/admin/flags/{key}", put(upsert))
        .route("/v1/flags", get(public_flags))
}

#[derive(Serialize, sqlx::FromRow)]
struct Flag {
    key: String,
    enabled: bool,
    description: Option<String>,
    updated_by: Option<Uuid>,
    updated_at: DateTime<Utc>,
}

async fn list(State(st): State<AppState>, _staff: StaffUser) -> AppResult<Json<Vec<Flag>>> {
    let rows: Vec<Flag> = sqlx::query_as(
        "SELECT key, enabled, description, updated_by, updated_at FROM feature_flags ORDER BY key",
    )
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
struct FlagUpdate {
    enabled: bool,
    description: Option<String>,
}

async fn upsert(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Path(key): Path<String>,
    Json(body): Json<FlagUpdate>,
) -> AppResult<Json<Flag>> {
    if key.trim().is_empty() {
        return Err(AppError::BadRequest("flag key is required".into()));
    }
    let flag: Flag = sqlx::query_as(
        "INSERT INTO feature_flags (key, enabled, description, updated_by, updated_at) \
         VALUES ($1, $2, $3, $4, now()) \
         ON CONFLICT (key) DO UPDATE SET \
             enabled = EXCLUDED.enabled, \
             description = COALESCE(EXCLUDED.description, feature_flags.description), \
             updated_by = EXCLUDED.updated_by, \
             updated_at = now() \
         RETURNING key, enabled, description, updated_by, updated_at",
    )
    .bind(key.trim())
    .bind(body.enabled)
    .bind(body.description)
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(flag))
}

/// Apps read this to know which features are live (e.g. hide the bargain UI when
/// bargaining is off). Any authenticated user may read it.
async fn public_flags(
    State(st): State<AppState>,
    _auth: AuthUser,
) -> AppResult<Json<serde_json::Value>> {
    let rows: Vec<(String, bool)> =
        sqlx::query_as("SELECT key, enabled FROM feature_flags ORDER BY key")
            .fetch_all(&st.db)
            .await?;
    let map: serde_json::Map<String, serde_json::Value> = rows
        .into_iter()
        .map(|(k, v)| (k, serde_json::Value::Bool(v)))
        .collect();
    Ok(Json(serde_json::Value::Object(map)))
}
