//! Campaign (discount / bonus) management — staff-created, applied at estimate.

use crate::auth::{AuthUser, StaffUser};
use crate::error::{AppError, AppResult};
use crate::models::{Campaign, CAMPAIGN_COLS};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::Deserialize;
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/admin/campaigns", get(list).post(create))
        .route("/v1/admin/campaigns/{id}/deactivate", post(deactivate))
        .route("/v1/campaigns/{code}", get(preview))
}

#[derive(Deserialize)]
struct NewCampaign {
    code: String,
    title: String,
    audience: String, // rider | driver
    kind: String,     // percent | flat
    value: Decimal,
    #[serde(default)]
    min_fare: Option<Decimal>,
    max_discount: Option<Decimal>,
    city: Option<String>,
    vehicle_class: Option<String>,
    starts_at: Option<DateTime<Utc>>,
    ends_at: Option<DateTime<Utc>>,
    usage_limit: Option<i32>,
}

async fn create(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Json(body): Json<NewCampaign>,
) -> AppResult<Json<Campaign>> {
    if !matches!(body.audience.as_str(), "rider" | "driver") {
        return Err(AppError::BadRequest("audience must be 'rider' or 'driver'".into()));
    }
    if !matches!(body.kind.as_str(), "percent" | "flat") {
        return Err(AppError::BadRequest("kind must be 'percent' or 'flat'".into()));
    }
    if body.code.trim().is_empty() {
        return Err(AppError::BadRequest("code is required".into()));
    }

    let campaign: Campaign = sqlx::query_as(&format!(
        "INSERT INTO campaigns (code, title, audience, kind, value, min_fare, max_discount, city, \
            vehicle_class, starts_at, ends_at, usage_limit, created_by) \
         VALUES ($1,$2,$3::campaign_audience,$4::discount_kind,$5,$6,$7,$8,$9,$10,$11,$12,$13) \
         RETURNING {CAMPAIGN_COLS}"
    ))
    .bind(body.code.trim())
    .bind(body.title)
    .bind(body.audience)
    .bind(body.kind)
    .bind(body.value)
    .bind(body.min_fare.unwrap_or(Decimal::ZERO))
    .bind(body.max_discount)
    .bind(body.city)
    .bind(body.vehicle_class)
    .bind(body.starts_at)
    .bind(body.ends_at)
    .bind(body.usage_limit)
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await
    .map_err(|e| match e {
        sqlx::Error::Database(db) if db.is_unique_violation() => {
            AppError::Conflict("a campaign with that code already exists".into())
        }
        other => AppError::Db(other),
    })?;

    Ok(Json(campaign))
}

async fn list(State(st): State<AppState>, _staff: StaffUser) -> AppResult<Json<Vec<Campaign>>> {
    let rows: Vec<Campaign> =
        sqlx::query_as(&format!("SELECT {CAMPAIGN_COLS} FROM campaigns ORDER BY created_at DESC"))
            .fetch_all(&st.db)
            .await?;
    Ok(Json(rows))
}

async fn deactivate(
    State(st): State<AppState>,
    _staff: StaffUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<serde_json::Value>> {
    let res = sqlx::query("UPDATE campaigns SET active = false WHERE id = $1")
        .bind(id)
        .execute(&st.db)
        .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(Json(serde_json::json!({ "ok": true })))
}

async fn preview(
    State(st): State<AppState>,
    _auth: AuthUser,
    Path(code): Path<String>,
) -> AppResult<Json<Campaign>> {
    let campaign: Campaign = sqlx::query_as(&format!(
        "SELECT {CAMPAIGN_COLS} FROM campaigns WHERE code = $1 AND active = true \
           AND (starts_at IS NULL OR starts_at <= now()) \
           AND (ends_at IS NULL OR ends_at >= now())"
    ))
    .bind(code)
    .fetch_optional(&st.db)
    .await?
    .ok_or(AppError::NotFound)?;
    Ok(Json(campaign))
}
