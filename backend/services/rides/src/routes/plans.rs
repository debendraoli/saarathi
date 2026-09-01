//! Credit top-up plans with a maker-checker workflow: staff create/edit (→
//! pending); admin/super-admin approve or reject (→ active/rejected). Only
//! active plans are shown to riders.

use crate::auth::{AuthUser, StaffUser};
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{
    Json, Router,
    routing::{get, post, put},
};
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use saarathi_core::api::ErrorCode;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/admin/credit-plans", get(list).post(create))
        .route("/v1/admin/credit-plans/{id}", put(update))
        .route("/v1/admin/credit-plans/{id}/approve", post(approve))
        .route("/v1/admin/credit-plans/{id}/reject", post(reject))
        .route("/v1/credit-plans", get(active))
}

#[derive(Serialize, sqlx::FromRow)]
struct Plan {
    id: Uuid,
    name: String,
    min_amount: Decimal,
    max_amount: Decimal,
    bonus_percent: Decimal,
    status: String,
    review_note: Option<String>,
    created_at: DateTime<Utc>,
}

const PLAN_COLS: &str =
    "id, name, min_amount, max_amount, bonus_percent, status, review_note, created_at";

#[derive(Deserialize)]
struct NewPlan {
    name: String,
    min_amount: Decimal,
    max_amount: Decimal,
    #[serde(default)]
    bonus_percent: Option<Decimal>,
}

fn validate(name: &str, min: Decimal, max: Decimal) -> AppResult<()> {
    if name.trim().is_empty() {
        return Err(AppError::bad(ErrorCode::PlanInvalid, "name is required"));
    }
    if min <= Decimal::ZERO || max < min {
        return Err(AppError::bad(
            ErrorCode::PlanInvalid,
            "require 0 < min_amount ≤ max_amount",
        ));
    }
    Ok(())
}

async fn create(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Json(body): Json<NewPlan>,
) -> AppResult<Json<Plan>> {
    validate(&body.name, body.min_amount, body.max_amount)?;
    let plan: Plan = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "INSERT INTO credit_plans (name, min_amount, max_amount, bonus_percent, created_by) \
         VALUES ($1, $2, $3, $4, $5) RETURNING {PLAN_COLS}"
    )))
    .bind(body.name)
    .bind(body.min_amount)
    .bind(body.max_amount)
    .bind(body.bonus_percent.unwrap_or(Decimal::ZERO))
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(plan))
}

#[derive(Deserialize)]
struct EditPlan {
    name: Option<String>,
    min_amount: Option<Decimal>,
    max_amount: Option<Decimal>,
    bonus_percent: Option<Decimal>,
}

async fn update(
    State(st): State<AppState>,
    _staff: StaffUser,
    Path(id): Path<Uuid>,
    Json(body): Json<EditPlan>,
) -> AppResult<Json<Plan>> {
    // Any edit sends the plan back through approval.
    let plan: Plan = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "UPDATE credit_plans SET \
            name = COALESCE($2, name), \
            min_amount = COALESCE($3, min_amount), \
            max_amount = COALESCE($4, max_amount), \
            bonus_percent = COALESCE($5, bonus_percent), \
            status = 'pending', approved_by = NULL, approved_at = NULL, updated_at = now() \
         WHERE id = $1 RETURNING {PLAN_COLS}"
    )))
    .bind(id)
    .bind(body.name)
    .bind(body.min_amount)
    .bind(body.max_amount)
    .bind(body.bonus_percent)
    .fetch_optional(&st.db)
    .await?
    .ok_or(AppError::NotFound)?;
    validate(&plan.name, plan.min_amount, plan.max_amount)?;
    Ok(Json(plan))
}

async fn approve(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    if !claims.can_approve() {
        return Err(AppError::Forbidden);
    }
    let res = sqlx::query(
        "UPDATE credit_plans SET status = 'active', approved_by = $2, approved_at = now(), updated_at = now() \
         WHERE id = $1",
    )
    .bind(id)
    .bind(claims.sub)
    .execute(&st.db)
    .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(Json(json!({ "status": "active" })))
}

#[derive(Deserialize)]
struct RejectPlan {
    note: Option<String>,
}

async fn reject(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Path(id): Path<Uuid>,
    Json(body): Json<RejectPlan>,
) -> AppResult<Json<Value>> {
    if !claims.can_approve() {
        return Err(AppError::Forbidden);
    }
    let res = sqlx::query(
        "UPDATE credit_plans SET status = 'rejected', approved_by = $2, review_note = $3, updated_at = now() \
         WHERE id = $1",
    )
    .bind(id)
    .bind(claims.sub)
    .bind(body.note)
    .execute(&st.db)
    .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(Json(json!({ "status": "rejected" })))
}

async fn list(State(st): State<AppState>, _staff: StaffUser) -> AppResult<Json<Vec<Plan>>> {
    let rows: Vec<Plan> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {PLAN_COLS} FROM credit_plans ORDER BY (status = 'pending') DESC, created_at DESC"
    )))
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

/// Active plans only — what riders may top up against.
async fn active(State(st): State<AppState>, _auth: AuthUser) -> AppResult<Json<Vec<Plan>>> {
    let rows: Vec<Plan> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {PLAN_COLS} FROM credit_plans WHERE status = 'active' ORDER BY min_amount"
    )))
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}
