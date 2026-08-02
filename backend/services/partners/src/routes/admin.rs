//! Platform-admin partner governance: onboard fleet partners, set their
//! commission share, suspend/activate. Staff-only (super_admin / admin).

use crate::audit;
use crate::auth::AdminUser;
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::extract::{Path, Query, State};
use axum::{routing::get, Json, Router};
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use saarathi_core::legal::MAX_COMMISSION_RATE;
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/admin/partners", get(list).post(create))
        .route("/v1/admin/partners/{id}", get(detail).put(update))
}

#[derive(Serialize, sqlx::FromRow)]
struct Partner {
    id: Uuid,
    name: String,
    legal_name: Option<String>,
    #[sqlx(rename = "type")]
    partner_type: String,
    status: String,
    city: Option<String>,
    contact_phone: Option<String>,
    contact_email: Option<String>,
    pan_vat: Option<String>,
    commission_share: Decimal,
    created_at: DateTime<Utc>,
}

const PARTNER_COLS: &str = "id, name, legal_name, type::text AS \"type\", status::text AS status, \
    city, contact_phone, contact_email, pan_vat, commission_share, created_at";

#[derive(Deserialize)]
struct NewPartner {
    name: String,
    owner_phone: String,
    legal_name: Option<String>,
    #[serde(default)]
    partner_type: Option<String>,
    city: Option<String>,
    contact_email: Option<String>,
    pan_vat: Option<String>,
    #[serde(default)]
    commission_share: Option<Decimal>,
}

async fn create(
    State(st): State<AppState>,
    AdminUser(claims): AdminUser,
    Json(body): Json<NewPartner>,
) -> AppResult<Json<Partner>> {
    if body.name.trim().is_empty() {
        return Err(AppError::BadRequest("name is required".into()));
    }
    let owner_phone = body.owner_phone.trim();
    if owner_phone.is_empty() {
        return Err(AppError::BadRequest("owner_phone is required".into()));
    }
    let ptype = body.partner_type.unwrap_or_else(|| "fleet".into());
    if !matches!(ptype.as_str(), "fleet" | "corporate" | "agent") {
        return Err(AppError::BadRequest(
            "partner_type must be 'fleet', 'corporate', or 'agent'".into(),
        ));
    }
    // Partner share is carved from (and clamped to) the legal commission cap.
    let share = body
        .commission_share
        .unwrap_or(Decimal::ZERO)
        .max(Decimal::ZERO)
        .min(MAX_COMMISSION_RATE);

    let mut tx = st.db.begin().await?;
    let partner: Partner = sqlx::query_as(&format!(
        "INSERT INTO partners (name, legal_name, type, city, contact_phone, contact_email, \
            pan_vat, commission_share, onboarded_by) \
         VALUES ($1,$2,$3::partner_type,$4,$5,$6,$7,$8,$9) RETURNING {PARTNER_COLS}"
    ))
    .bind(body.name.trim())
    .bind(body.legal_name)
    .bind(&ptype)
    .bind(body.city)
    .bind(owner_phone)
    .bind(body.contact_email)
    .bind(body.pan_vat)
    .bind(share)
    .bind(claims.sub)
    .fetch_one(&mut *tx)
    .await?;

    // Create/find the owner user and seat them as the partner owner.
    let owner_id: Uuid = sqlx::query_scalar(
        "INSERT INTO users (phone, role, status) VALUES ($1, 'rider', 'active') \
         ON CONFLICT (phone) DO UPDATE SET phone = EXCLUDED.phone RETURNING id",
    )
    .bind(owner_phone)
    .fetch_one(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO partner_members (partner_id, user_id, role, invited_by) \
         VALUES ($1, $2, 'owner', $3)",
    )
    .bind(partner.id)
    .bind(owner_id)
    .bind(claims.sub)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    audit::record(
        &st.db,
        claims.sub,
        "partner.create",
        "partner",
        partner.id,
        json!({ "owner_phone": owner_phone }),
    )
    .await?;
    Ok(Json(partner))
}

#[derive(Deserialize)]
struct ListQuery {
    status: Option<String>,
}

async fn list(
    State(st): State<AppState>,
    _admin: AdminUser,
    Query(q): Query<ListQuery>,
) -> AppResult<Json<Vec<Partner>>> {
    let rows: Vec<Partner> = match q.status {
        Some(s) => sqlx::query_as(&format!(
            "SELECT {PARTNER_COLS} FROM partners WHERE status::text = $1 ORDER BY created_at DESC"
        ))
        .bind(s)
        .fetch_all(&st.db)
        .await?,
        None => {
            sqlx::query_as(&format!(
                "SELECT {PARTNER_COLS} FROM partners ORDER BY created_at DESC"
            ))
            .fetch_all(&st.db)
            .await?
        }
    };
    Ok(Json(rows))
}

#[derive(Serialize)]
struct PartnerDetail {
    partner: Partner,
    member_count: i64,
    driver_count: i64,
}

async fn detail(
    State(st): State<AppState>,
    _admin: AdminUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<PartnerDetail>> {
    let partner: Partner = sqlx::query_as(&format!(
        "SELECT {PARTNER_COLS} FROM partners WHERE id = $1"
    ))
    .bind(id)
    .fetch_optional(&st.db)
    .await?
    .ok_or(AppError::NotFound)?;
    let member_count: i64 =
        sqlx::query_scalar("SELECT count(*) FROM partner_members WHERE partner_id = $1")
            .bind(id)
            .fetch_one(&st.db)
            .await?;
    let driver_count: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM partner_drivers WHERE partner_id = $1 AND status = 'active'",
    )
    .bind(id)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(PartnerDetail {
        partner,
        member_count,
        driver_count,
    }))
}

#[derive(Deserialize)]
struct UpdatePartner {
    status: Option<String>,
    commission_share: Option<Decimal>,
    city: Option<String>,
    contact_email: Option<String>,
}

async fn update(
    State(st): State<AppState>,
    AdminUser(claims): AdminUser,
    Path(id): Path<Uuid>,
    Json(body): Json<UpdatePartner>,
) -> AppResult<Json<Partner>> {
    if let Some(s) = &body.status {
        if !matches!(
            s.as_str(),
            "pending" | "active" | "suspended" | "terminated"
        ) {
            return Err(AppError::BadRequest("invalid status".into()));
        }
    }
    let share = body
        .commission_share
        .map(|s| s.max(Decimal::ZERO).min(MAX_COMMISSION_RATE));

    let partner: Partner = sqlx::query_as(&format!(
        "UPDATE partners SET \
            status = COALESCE($2::partner_status, status), \
            commission_share = COALESCE($3, commission_share), \
            city = COALESCE($4, city), \
            contact_email = COALESCE($5, contact_email), \
            updated_at = now() \
         WHERE id = $1 RETURNING {PARTNER_COLS}"
    ))
    .bind(id)
    .bind(body.status)
    .bind(share)
    .bind(body.city)
    .bind(body.contact_email)
    .fetch_optional(&st.db)
    .await?
    .ok_or(AppError::NotFound)?;

    audit::record(
        &st.db,
        claims.sub,
        "partner.update",
        "partner",
        id,
        json!({}),
    )
    .await?;
    Ok(Json(partner))
}
