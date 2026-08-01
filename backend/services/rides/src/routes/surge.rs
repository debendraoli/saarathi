//! Surge-window management (dashboard-controlled time-of-day surcharge).
//! Every configured multiplier is still hard-clamped to the legal +20% by the
//! pricing engine — this only lets ops shape *when* a (bounded) surge applies.

use crate::auth::StaffUser;
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/admin/surge", get(list).post(create))
        .route("/v1/admin/surge/{id}/deactivate", post(deactivate))
}

#[derive(Serialize, sqlx::FromRow)]
struct SurgeWindow {
    id: Uuid,
    label: String,
    start_minute: i32,
    end_minute: i32,
    multiplier: Decimal,
    days_mask: i32,
    vehicle_class: Option<String>,
    city: Option<String>,
    active: bool,
    created_at: DateTime<Utc>,
}

async fn list(State(st): State<AppState>, _staff: StaffUser) -> AppResult<Json<Vec<SurgeWindow>>> {
    let rows: Vec<SurgeWindow> = sqlx::query_as(
        "SELECT id, label, start_minute, end_minute, multiplier, days_mask, vehicle_class, city, \
                active, created_at \
         FROM surge_windows ORDER BY created_at DESC",
    )
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
struct NewSurgeWindow {
    label: String,
    start_minute: i32,
    end_minute: i32,
    multiplier: Decimal,
    #[serde(default = "all_days")]
    days_mask: i32,
    vehicle_class: Option<String>,
    city: Option<String>,
}

fn all_days() -> i32 {
    127
}

async fn create(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Json(body): Json<NewSurgeWindow>,
) -> AppResult<Json<SurgeWindow>> {
    if body.label.trim().is_empty() {
        return Err(AppError::BadRequest("label is required".into()));
    }
    if !(0..=1440).contains(&body.start_minute) || !(0..=1440).contains(&body.end_minute) {
        return Err(AppError::BadRequest(
            "start_minute and end_minute must be within [0, 1440]".into(),
        ));
    }
    if body.multiplier < Decimal::ONE {
        return Err(AppError::BadRequest(
            "multiplier must be at least 1.0".into(),
        ));
    }
    let win: SurgeWindow = sqlx::query_as(
        "INSERT INTO surge_windows (label, start_minute, end_minute, multiplier, days_mask, \
            vehicle_class, city, created_by) \
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8) \
         RETURNING id, label, start_minute, end_minute, multiplier, days_mask, vehicle_class, \
                   city, active, created_at",
    )
    .bind(body.label.trim())
    .bind(body.start_minute)
    .bind(body.end_minute)
    .bind(body.multiplier)
    .bind(body.days_mask)
    .bind(body.vehicle_class)
    .bind(body.city)
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(win))
}

async fn deactivate(
    State(st): State<AppState>,
    _staff: StaffUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<serde_json::Value>> {
    let res = sqlx::query("UPDATE surge_windows SET active = false WHERE id = $1")
        .bind(id)
        .execute(&st.db)
        .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(Json(serde_json::json!({ "ok": true })))
}
