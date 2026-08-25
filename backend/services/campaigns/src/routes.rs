//! Campaign (discount / bonus) **management** — staff CRUD + rider preview.
//! Rides evaluates these at estimate/bonus time (reads the same `campaigns`
//! table); this service owns creation/validation. Shared Postgres DB with rides,
//! which owns the campaign schema.

use crate::auth::{AuthUser, StaffUser};
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::extract::{Path, Query, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use saarathi_core::api::ErrorCode;
use saarathi_core::domain::roles;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

const CAMPAIGN_COLS: &str = "id, code, title, audience::text AS audience, kind::text AS kind, \
    value, min_fare, max_discount, city, vehicle_class, starts_at, ends_at, active, \
    usage_limit, used_count, rules, created_at";

#[derive(Debug, Serialize, sqlx::FromRow)]
struct Campaign {
    id: Uuid,
    code: String,
    title: String,
    audience: String,
    kind: String,
    value: Decimal,
    min_fare: Decimal,
    max_discount: Option<Decimal>,
    city: Option<String>,
    vehicle_class: Option<String>,
    starts_at: Option<DateTime<Utc>>,
    ends_at: Option<DateTime<Utc>>,
    active: bool,
    usage_limit: Option<i32>,
    used_count: i32,
    rules: serde_json::Value,
    created_at: DateTime<Utc>,
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/admin/campaigns", get(list).post(create))
        .route("/v1/admin/campaigns/{id}/deactivate", post(deactivate))
        .route("/v1/campaigns/{code}", get(preview))
        .route("/v1/campaigns/active", get(active))
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
    /// Dynamic eligibility rules (ANDed). See `saarathi_core::campaigns::CampaignRule`.
    #[serde(default)]
    rules: Option<serde_json::Value>,
}

/// Field-level validation for a new campaign, checked before it ever reaches
/// the DB. Pulled out of the handler so it's testable without an `AppState`.
fn validate_new_campaign(audience: &str, kind: &str, code: &str, value: Decimal) -> Result<(), String> {
    if !matches!(audience, roles::RIDER | roles::DRIVER) {
        return Err("audience must be 'rider' or 'driver'".into());
    }
    if !matches!(kind, "percent" | "flat") {
        return Err("kind must be 'percent' or 'flat'".into());
    }
    if code.trim().is_empty() {
        return Err("code is required".into());
    }
    if kind == "percent" && (value <= Decimal::ZERO || value > Decimal::from(100)) {
        return Err("percent value must be between 0 and 100".into());
    }
    Ok(())
}

async fn create(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Json(body): Json<NewCampaign>,
) -> AppResult<Json<Campaign>> {
    validate_new_campaign(&body.audience, &body.kind, &body.code, body.value)
        .map_err(AppError::BadRequest)?;
    // Validate the rule payload up front so bad rules never reach the engine.
    let rules = body.rules.unwrap_or_else(|| serde_json::json!([]));
    saarathi_core::campaigns::parse_rules(&rules).map_err(AppError::BadRequest)?;

    let campaign: Campaign = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "INSERT INTO campaigns (code, title, audience, kind, value, min_fare, max_discount, city, \
            vehicle_class, starts_at, ends_at, usage_limit, rules, created_by) \
         VALUES ($1,$2,$3::campaign_audience,$4::discount_kind,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14) \
         RETURNING {CAMPAIGN_COLS}"
    )))
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
    .bind(rules)
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await
    .map_err(|e| match e {
        sqlx::Error::Database(db) if db.is_unique_violation() => AppError::conflict(
            ErrorCode::DuplicateCode,
            "a campaign with that code already exists",
        ),
        other => AppError::Db(other),
    })?;

    Ok(Json(campaign))
}

async fn list(State(st): State<AppState>, _staff: StaffUser) -> AppResult<Json<Vec<Campaign>>> {
    let rows: Vec<Campaign> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {CAMPAIGN_COLS} FROM campaigns ORDER BY created_at DESC"
    )))
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

#[derive(Deserialize)]
struct ActiveQuery {
    #[serde(default)]
    audience: Option<String>,
}

/// Active, in-window campaigns for the home-screen offers banner — no code
/// needed, just a browse list. Defaults to `audience='rider'` since that's
/// the only home surface consuming this today.
async fn active(
    State(st): State<AppState>,
    _auth: AuthUser,
    Query(q): Query<ActiveQuery>,
) -> AppResult<Json<Vec<Campaign>>> {
    let audience = q.audience.as_deref().unwrap_or(roles::RIDER);
    let rows: Vec<Campaign> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {CAMPAIGN_COLS} FROM campaigns \
         WHERE audience = $1::campaign_audience AND active = true \
           AND (starts_at IS NULL OR starts_at <= now()) \
           AND (ends_at IS NULL OR ends_at >= now()) \
         ORDER BY created_at DESC"
    )))
    .bind(audience)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

async fn preview(
    State(st): State<AppState>,
    _auth: AuthUser,
    Path(code): Path<String>,
) -> AppResult<Json<Campaign>> {
    let campaign: Campaign = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {CAMPAIGN_COLS} FROM campaigns WHERE code = $1 AND active = true \
           AND (starts_at IS NULL OR starts_at <= now()) \
           AND (ends_at IS NULL OR ends_at >= now())"
    )))
    .bind(code)
    .fetch_optional(&st.db)
    .await?
    .ok_or(AppError::NotFound)?;
    Ok(Json(campaign))
}

#[cfg(test)]
mod validate_new_campaign_tests {
    use super::*;
    use rust_decimal_macros::dec;

    #[test]
    fn accepts_a_well_formed_flat_campaign() {
        assert!(validate_new_campaign("rider", "flat", "WELCOME50", dec!(50)).is_ok());
    }

    #[test]
    fn accepts_a_well_formed_percent_campaign() {
        assert!(validate_new_campaign("driver", "percent", "BONUS10", dec!(10)).is_ok());
    }

    #[test]
    fn rejects_an_unknown_audience() {
        assert!(validate_new_campaign("merchant", "flat", "X", dec!(10)).is_err());
    }

    #[test]
    fn rejects_an_unknown_kind() {
        assert!(validate_new_campaign("rider", "fixed", "X", dec!(10)).is_err());
    }

    #[test]
    fn rejects_blank_or_whitespace_only_code() {
        assert!(validate_new_campaign("rider", "flat", "", dec!(10)).is_err());
        assert!(validate_new_campaign("rider", "flat", "   ", dec!(10)).is_err());
    }

    #[test]
    fn rejects_percent_value_out_of_0_to_100_range() {
        assert!(validate_new_campaign("rider", "percent", "X", dec!(0)).is_err());
        assert!(validate_new_campaign("rider", "percent", "X", dec!(-5)).is_err());
        assert!(validate_new_campaign("rider", "percent", "X", dec!(100.01)).is_err());
    }

    #[test]
    fn percent_value_of_exactly_100_is_allowed() {
        assert!(validate_new_campaign("rider", "percent", "X", dec!(100)).is_ok());
    }

    #[test]
    fn flat_kind_has_no_percent_range_restriction() {
        // A flat NPR discount can legitimately exceed 100 (e.g. NPR 500 off).
        assert!(validate_new_campaign("rider", "flat", "X", dec!(500)).is_ok());
    }
}
