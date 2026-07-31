//! Notification inbox endpoints (E8). The durable in-app record.

use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/notifications", get(inbox))
        .route("/v1/notifications/{id}/read", post(mark_read))
        .route("/v1/notifications/read-all", post(read_all))
}

#[derive(Serialize, sqlx::FromRow)]
struct Notification {
    id: Uuid,
    class: String,
    title: String,
    body: Option<String>,
    read_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
}

async fn inbox(State(st): State<AppState>, AuthUser(claims): AuthUser) -> AppResult<Json<Value>> {
    let items: Vec<Notification> = sqlx::query_as(
        "SELECT id, class, title, body, read_at, created_at FROM notifications \
         WHERE user_id = $1 ORDER BY created_at DESC LIMIT 100",
    )
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;
    let unread = items.iter().filter(|n| n.read_at.is_none()).count();
    Ok(Json(json!({ "unread": unread, "items": items })))
}

async fn mark_read(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let res = sqlx::query(
        "UPDATE notifications SET read_at = now() WHERE id = $1 AND user_id = $2 AND read_at IS NULL",
    )
    .bind(id)
    .bind(claims.sub)
    .execute(&st.db)
    .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(Json(json!({ "ok": true })))
}

async fn read_all(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Value>> {
    sqlx::query("UPDATE notifications SET read_at = now() WHERE user_id = $1 AND read_at IS NULL")
        .bind(claims.sub)
        .execute(&st.db)
        .await?;
    Ok(Json(json!({ "ok": true })))
}
