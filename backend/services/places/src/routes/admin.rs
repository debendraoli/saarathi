//! Staff review queue: list/detail/photo are any staff role, approve/reject
//! are admin/super-admin only (maker-checker) — same split as auth's driver
//! KYC review (`services/auth/src/routes/admin_routes.rs`).

use crate::auth::{AdminUser, StaffUser};
use crate::error::{AppError, AppResult};
use crate::points;
use crate::state::AppState;
use axum::body::Bytes;
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::IntoResponse;
use axum::{
    Json, Router,
    routing::{get, post},
};
use saarathi_core::api::ErrorCode;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/admin/places/contributions", get(queue))
        .route("/v1/admin/places/contributions/{id}", get(detail))
        .route("/v1/admin/places/contributions/{id}/photo", get(photo))
        .route("/v1/admin/places/contributions/{id}/approve", post(approve))
        .route("/v1/admin/places/contributions/{id}/reject", post(reject))
}

#[derive(Serialize, sqlx::FromRow)]
struct AdminContribution {
    id: Uuid,
    contributor_id: Uuid,
    category: String,
    name: String,
    description: Option<String>,
    lat: f64,
    lng: f64,
    capture_lat: f64,
    capture_lng: f64,
    capture_distance_m: f64,
    status: String,
    rejection_reason: Option<String>,
    reviewed_by: Option<Uuid>,
    reviewed_at: Option<chrono::DateTime<chrono::Utc>>,
    points_awarded: Option<i32>,
    created_at: chrono::DateTime<chrono::Utc>,
}

const ADMIN_COLS: &str = "id, contributor_id, category::text AS category, name, description, \
    lat, lng, capture_lat, capture_lng, capture_distance_m, status, rejection_reason, \
    reviewed_by, reviewed_at, points_awarded, created_at";

#[derive(Deserialize)]
struct QueueQuery {
    status: Option<String>,
}

async fn queue(
    State(st): State<AppState>,
    StaffUser(_claims): StaffUser,
    Query(q): Query<QueueQuery>,
) -> AppResult<Json<Value>> {
    let status = q.status.unwrap_or_else(|| "pending".into());
    let items: Vec<AdminContribution> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {ADMIN_COLS} FROM place_contributions \
         WHERE status = $1 ORDER BY created_at ASC LIMIT 200"
    )))
    .bind(&status)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(json!({ "items": items })))
}

async fn detail(
    State(st): State<AppState>,
    StaffUser(_claims): StaffUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<AdminContribution>> {
    let row: AdminContribution = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {ADMIN_COLS} FROM place_contributions WHERE id = $1"
    )))
    .bind(id)
    .fetch_optional(&st.db)
    .await?
    .ok_or(AppError::NotFound)?;
    Ok(Json(row))
}

async fn photo(
    State(st): State<AppState>,
    StaffUser(_claims): StaffUser,
    Path(id): Path<Uuid>,
) -> AppResult<impl IntoResponse> {
    let key: Option<String> =
        sqlx::query_scalar("SELECT photo_storage_key FROM place_contributions WHERE id = $1")
            .bind(id)
            .fetch_optional(&st.db)
            .await?;
    let key = key.ok_or(AppError::NotFound)?;
    let bytes = st.docs.get(&key).await.map_err(AppError::Other)?;
    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        "application/octet-stream".parse().unwrap(),
    );
    Ok((StatusCode::OK, headers, Bytes::from(bytes)))
}

async fn approve(
    State(st): State<AppState>,
    AdminUser(claims): AdminUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let mut tx = st.db.begin().await?;

    // Guarded on current status so two staff acting on the same submission
    // at once can't both approve it — same pattern as driver KYC approve.
    let row: Option<(Uuid, String, String, f64, f64)> = sqlx::query_as(
        "UPDATE place_contributions SET status = 'approved', reviewed_by = $2, reviewed_at = now() \
         WHERE id = $1 AND status = 'pending' \
         RETURNING contributor_id, category::text, name, lat, lng",
    )
    .bind(id)
    .bind(claims.sub)
    .fetch_optional(&mut *tx)
    .await?;
    let Some((contributor_id, category, name, lat, lng)) = row else {
        let exists: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM place_contributions WHERE id = $1)")
                .bind(id)
                .fetch_one(&mut *tx)
                .await?;
        return Err(if exists {
            AppError::conflict(ErrorCode::Conflict, "already reviewed")
        } else {
            AppError::NotFound
        });
    };

    let award = points::points_for(&category);
    sqlx::query("UPDATE place_contributions SET points_awarded = $2 WHERE id = $1")
        .bind(id)
        .bind(award)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        "INSERT INTO points_ledger (user_id, contribution_id, points, kind) \
         VALUES ($1, $2, $3, 'earned')",
    )
    .bind(contributor_id)
    .bind(id)
    .bind(award)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    // Badge check runs after commit — it reads the just-committed approved
    // count, and a missed badge on a rare NATS/notify hiccup is harmless
    // (it'll be caught on the next approval anyway).
    let new_badges = points::award_due_badges(&st.db, contributor_id)
        .await
        .unwrap_or_default();

    // Persistent, navigable places (not transient construction/closed-road
    // alerts) become findable via search/reverse-geocode immediately —
    // same best-effort convention as the badge check above.
    if points::is_navigable(&category) {
        saarathi_core::pelias_index::index_place(
            &st.config.pelias_es_url,
            id,
            &category,
            &name,
            lat,
            lng,
        )
        .await;
    }

    crate::notify::send(
        &st.nats,
        contributor_id,
        saarathi_core::domain::notif::TRANSACTIONAL,
        "Contribution approved",
        &format!("Your submission was approved — +{award} points."),
        Some("saarathi://places/points".to_string()),
    )
    .await;
    for badge in new_badges {
        crate::notify::send(
            &st.nats,
            contributor_id,
            saarathi_core::domain::notif::TRANSACTIONAL,
            "New badge earned",
            &format!("You earned the \"{}\" badge!", points::badge_title(badge)),
            Some("saarathi://places/points".to_string()),
        )
        .await;
    }

    Ok(Json(
        json!({ "ok": true, "status": "approved", "points_awarded": award }),
    ))
}

#[derive(Deserialize)]
struct RejectInput {
    reason: String,
}

async fn reject(
    State(st): State<AppState>,
    AdminUser(claims): AdminUser,
    Path(id): Path<Uuid>,
    Json(body): Json<RejectInput>,
) -> AppResult<Json<Value>> {
    if body.reason.trim().is_empty() {
        return Err(AppError::BadRequest(
            "a rejection reason is required".into(),
        ));
    }
    let row: Option<(Uuid,)> = sqlx::query_as(
        "UPDATE place_contributions SET status = 'rejected', reviewed_by = $2, reviewed_at = now(), \
         rejection_reason = $3 \
         WHERE id = $1 AND status = 'pending' RETURNING contributor_id",
    )
    .bind(id)
    .bind(claims.sub)
    .bind(&body.reason)
    .fetch_optional(&st.db)
    .await?;
    let Some((contributor_id,)) = row else {
        let exists: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM place_contributions WHERE id = $1)")
                .bind(id)
                .fetch_one(&st.db)
                .await?;
        return Err(if exists {
            AppError::conflict(ErrorCode::Conflict, "already reviewed")
        } else {
            AppError::NotFound
        });
    };

    crate::notify::send(
        &st.nats,
        contributor_id,
        saarathi_core::domain::notif::TRANSACTIONAL,
        "Contribution rejected",
        &format!("Your submission wasn't approved: {}", body.reason),
        None,
    )
    .await;

    Ok(Json(json!({ "ok": true, "status": "rejected" })))
}
