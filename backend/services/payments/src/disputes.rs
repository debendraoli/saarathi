//! Payment dispute claims — reuses the `reports` table/lifecycle
//! (open → investigating → resolved | dismissed) that `saarathi-rides`
//! already has for ride grievances, rather than a parallel schema. What makes
//! these disputes rather than plain reports is `reference`: a specific
//! money-moving transaction (a payout/topup reference, or a credit_transaction
//! id) instead of just a trip.

use crate::auth::{AuthUser, StaffUser};
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use saarathi_core::api::ErrorCode;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/disputes", get(list_mine).post(create))
        .route("/v1/admin/disputes", get(list_all))
        .route("/v1/admin/disputes/{id}/status", post(update_status))
}

#[derive(Deserialize)]
struct CreateDispute {
    /// The payout/topup reference or credit_transaction id being disputed.
    reference: String,
    detail: String,
}

async fn create(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<CreateDispute>,
) -> AppResult<Json<Value>> {
    if body.reference.trim().is_empty() || body.detail.trim().is_empty() {
        return Err(AppError::bad(
            ErrorCode::Validation,
            "reference and detail are required",
        ));
    }
    let (id,): (Uuid,) = sqlx::query_as(
        "INSERT INTO reports (reporter_id, category, detail, reference, severity) \
         VALUES ($1, 'payment', $2, $3, 'normal') RETURNING id",
    )
    .bind(claims.sub)
    .bind(&body.detail)
    .bind(&body.reference)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({ "id": id, "status": "open" })))
}

#[derive(Serialize, sqlx::FromRow)]
struct Dispute {
    id: Uuid,
    reporter_id: Uuid,
    reference: Option<String>,
    detail: Option<String>,
    status: String,
    resolution: Option<String>,
    created_at: DateTime<Utc>,
    resolved_at: Option<DateTime<Utc>>,
}

const DISPUTE_COLS: &str =
    "id, reporter_id, reference, detail, status, resolution, created_at, resolved_at";

async fn list_mine(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Vec<Dispute>>> {
    let rows: Vec<Dispute> = sqlx::query_as(&format!(
        "SELECT {DISPUTE_COLS} FROM reports \
         WHERE reporter_id = $1 AND reference IS NOT NULL \
         ORDER BY created_at DESC LIMIT 100"
    ))
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

async fn list_all(State(st): State<AppState>, _staff: StaffUser) -> AppResult<Json<Vec<Dispute>>> {
    let rows: Vec<Dispute> = sqlx::query_as(&format!(
        "SELECT {DISPUTE_COLS} FROM reports \
         WHERE reference IS NOT NULL \
         ORDER BY (status = 'open') DESC, created_at DESC LIMIT 200"
    ))
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
struct UpdateStatus {
    status: String,
    resolution: Option<String>,
}

async fn update_status(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Path(id): Path<Uuid>,
    Json(body): Json<UpdateStatus>,
) -> AppResult<Json<Value>> {
    if !matches!(body.status.as_str(), "investigating" | "resolved" | "dismissed") {
        return Err(AppError::bad(
            ErrorCode::Validation,
            "status must be 'investigating', 'resolved', or 'dismissed'",
        ));
    }
    let resolved_at = matches!(body.status.as_str(), "resolved" | "dismissed");
    let row: Option<(Uuid,)> = sqlx::query_as(
        "UPDATE reports SET status = $2, resolution = $3, handled_by = $4, \
         resolved_at = CASE WHEN $5 THEN now() ELSE resolved_at END \
         WHERE id = $1 AND reference IS NOT NULL RETURNING id",
    )
    .bind(id)
    .bind(&body.status)
    .bind(&body.resolution)
    .bind(claims.sub)
    .bind(resolved_at)
    .fetch_optional(&st.db)
    .await?;
    row.ok_or(AppError::NotFound)?;
    Ok(Json(json!({ "id": id, "status": body.status })))
}
