//! Ratings & reports (E7). Two-sided, tag-based ratings after a trip, plus a
//! categorised report/grievance queue for Ops.

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
        .route("/v1/rides/{id}/rate", post(rate))
        .route("/v1/drivers/{id}/rating", get(driver_rating))
        .route("/v1/reports", post(create_report))
        .route("/v1/admin/reports", get(list_reports))
        .route("/v1/admin/reports/{id}/resolve", post(resolve_report))
}

#[derive(Deserialize)]
struct RateRequest {
    stars: i32,
    #[serde(default)]
    tags: Vec<String>,
    comment: Option<String>,
}

async fn rate(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
    Json(b): Json<RateRequest>,
) -> AppResult<Json<Value>> {
    if !(1..=5).contains(&b.stars) {
        return Err(AppError::BadRequest("stars must be 1–5".into()));
    }
    let row: Option<(Uuid, Option<Uuid>, String)> =
        sqlx::query_as("SELECT rider_id, driver_id, status::text FROM trips WHERE id = $1")
            .bind(id)
            .fetch_optional(&st.db)
            .await?;
    let (rider, driver, status) = row.ok_or(AppError::NotFound)?;
    if status != "completed" {
        return Err(AppError::BadRequest(
            "can only rate a completed trip".into(),
        ));
    }
    let (ratee, role) = if rider == claims.sub {
        (
            driver.ok_or(AppError::BadRequest("no driver on trip".into()))?,
            "rider_rates_driver",
        )
    } else if driver == Some(claims.sub) {
        (rider, "driver_rates_rider")
    } else {
        return Err(AppError::Forbidden);
    };

    sqlx::query(
        "INSERT INTO ratings (trip_id, rater_id, ratee_id, role, stars, tags, comment) \
         VALUES ($1, $2, $3, $4, $5, $6, $7) \
         ON CONFLICT (trip_id, rater_id) DO UPDATE SET stars = EXCLUDED.stars, tags = EXCLUDED.tags, comment = EXCLUDED.comment",
    )
    .bind(id)
    .bind(claims.sub)
    .bind(ratee)
    .bind(role)
    .bind(b.stars)
    .bind(&b.tags)
    .bind(b.comment)
    .execute(&st.db)
    .await?;
    Ok(Json(json!({ "ok": true, "ratee": ratee })))
}

async fn driver_rating(
    State(st): State<AppState>,
    _auth: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let row: (Option<f64>, i64) =
        sqlx::query_as("SELECT avg(stars)::float8, count(*) FROM ratings WHERE ratee_id = $1 AND role = 'rider_rates_driver'")
            .bind(id)
            .fetch_one(&st.db)
            .await?;
    Ok(Json(
        json!({ "driver_id": id, "avg_stars": row.0, "count": row.1 }),
    ))
}

#[derive(Deserialize)]
struct ReportRequest {
    trip_id: Option<Uuid>,
    subject_id: Option<Uuid>,
    category: String,
    severity: Option<String>,
    detail: Option<String>,
}

async fn create_report(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(b): Json<ReportRequest>,
) -> AppResult<Json<Value>> {
    if b.category.trim().is_empty() {
        return Err(AppError::BadRequest("category is required".into()));
    }
    let severity = if b.category == "safety" {
        "high"
    } else {
        b.severity.as_deref().unwrap_or("normal")
    };
    let (report_id,): (Uuid,) = sqlx::query_as(
        "INSERT INTO reports (reporter_id, subject_id, trip_id, category, severity, detail) \
         VALUES ($1, $2, $3, $4, $5, $6) RETURNING id",
    )
    .bind(claims.sub)
    .bind(b.subject_id)
    .bind(b.trip_id)
    .bind(&b.category)
    .bind(severity)
    .bind(b.detail)
    .fetch_one(&st.db)
    .await?;
    notify::send(
        &st.nats,
        claims.sub,
        saarathi_core::domain::notif::TRANSACTIONAL,
        "Report received",
        "Our team will review it shortly.",
        None,
    )
    .await;
    Ok(Json(json!({ "id": report_id, "status": "open" })))
}

#[derive(Serialize, sqlx::FromRow)]
struct Report {
    id: Uuid,
    reporter_id: Uuid,
    subject_id: Option<Uuid>,
    trip_id: Option<Uuid>,
    category: String,
    severity: String,
    detail: Option<String>,
    status: String,
    resolution: Option<String>,
    created_at: DateTime<Utc>,
}

async fn list_reports(
    State(st): State<AppState>,
    _staff: StaffUser,
) -> AppResult<Json<Vec<Report>>> {
    let rows: Vec<Report> = sqlx::query_as(
        "SELECT id, reporter_id, subject_id, trip_id, category, severity, detail, status, resolution, created_at \
         FROM reports ORDER BY (status = 'open') DESC, created_at DESC LIMIT 200",
    )
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
struct ResolveReport {
    status: String,
    resolution: Option<String>,
}

async fn resolve_report(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Path(id): Path<Uuid>,
    Json(b): Json<ResolveReport>,
) -> AppResult<Json<Value>> {
    if !matches!(
        b.status.as_str(),
        "investigating" | "resolved" | "dismissed"
    ) {
        return Err(AppError::BadRequest("invalid status".into()));
    }
    let res = sqlx::query(
        "UPDATE reports SET status = $2, resolution = COALESCE($3, resolution), handled_by = $4, \
         resolved_at = CASE WHEN $2 IN ('resolved','dismissed') THEN now() ELSE resolved_at END \
         WHERE id = $1",
    )
    .bind(id)
    .bind(&b.status)
    .bind(b.resolution)
    .bind(claims.sub)
    .execute(&st.db)
    .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(Json(json!({ "ok": true })))
}
