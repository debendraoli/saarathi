//! Platform-admin partner governance: onboard fleet partners, set their
//! commission share, suspend/activate. Staff-only (super_admin / admin).

use crate::audit;
use crate::auth::AdminUser;
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::extract::{Path, Query, State};
use axum::{Json, Router, routing::get};
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
    // `#[serde(rename = "type")]` too, not just sqlx — the dashboard's
    // `Partner` type has always read `.type` off this response (confirmed
    // live: the type column has rendered blank ever since, since the JSON
    // key was `partner_type` with only the SQL-column side renamed).
    #[sqlx(rename = "type")]
    #[serde(rename = "type")]
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
    let partner: Partner = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "INSERT INTO partners (name, legal_name, type, city, contact_phone, contact_email, \
            pan_vat, commission_share, onboarded_by) \
         VALUES ($1,$2,$3::partner_type,$4,$5,$6,$7,$8,$9) RETURNING {PARTNER_COLS}"
    )))
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
    #[serde(default)]
    limit: Option<i64>,
    #[serde(default)]
    offset: Option<i64>,
}

async fn list(
    State(st): State<AppState>,
    _admin: AdminUser,
    Query(q): Query<ListQuery>,
) -> AppResult<Json<Vec<Partner>>> {
    let limit = q.limit.unwrap_or(20).clamp(1, 100);
    let offset = q.offset.unwrap_or(0).max(0);
    let rows: Vec<Partner> =
        match q.status {
            Some(s) => {
                sqlx::query_as(sqlx::AssertSqlSafe(format!(
                    "SELECT {PARTNER_COLS} FROM partners WHERE status::text = $1 \
             ORDER BY created_at DESC LIMIT $2 OFFSET $3"
                )))
                .bind(s)
                .bind(limit)
                .bind(offset)
                .fetch_all(&st.db)
                .await?
            }
            None => sqlx::query_as(sqlx::AssertSqlSafe(format!(
                "SELECT {PARTNER_COLS} FROM partners ORDER BY created_at DESC LIMIT $1 OFFSET $2"
            )))
            .bind(limit)
            .bind(offset)
            .fetch_all(&st.db)
            .await?,
        };
    Ok(Json(rows))
}

#[derive(Serialize, sqlx::FromRow)]
struct FleetDriver {
    driver_user_id: Uuid,
    full_name: Option<String>,
    phone: String,
    status: String,
    joined_at: DateTime<Utc>,
}

#[derive(Serialize, sqlx::FromRow)]
struct OwnedMerchant {
    id: Uuid,
    name: String,
    vertical: String,
    is_open: bool,
}

#[derive(Serialize)]
struct PartnerDetail {
    partner: Partner,
    member_count: i64,
    driver_count: i64,
    /// The partner's actual fleet roster, not just [driver_count] — the
    /// dashboard's partner detail page lists who's actually in it, same as
    /// it already does for a merchant's own driver-facing pages elsewhere.
    /// Every driver ever attached (not just currently-`active`), so a staff
    /// member can see who's left the fleet too — `status` distinguishes them.
    drivers: Vec<FleetDriver>,
    /// There's no `merchants.partner_id` column — a merchant only records a
    /// single `owner_user_id`, not a partner organization. The closest real
    /// signal without a schema migration: a merchant counts as this
    /// partner's if its owner is one of the partner's own members. Good
    /// enough for "how many merchants does this partner run" today; if
    /// partners start managing merchants through dedicated staff accounts
    /// distinct from their membership roster, this will need the real
    /// column instead.
    merchants: Vec<OwnedMerchant>,
}

async fn detail(
    State(st): State<AppState>,
    _admin: AdminUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<PartnerDetail>> {
    let partner: Partner = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {PARTNER_COLS} FROM partners WHERE id = $1"
    )))
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
    let drivers: Vec<FleetDriver> = sqlx::query_as(
        "SELECT pd.driver_user_id, u.full_name, u.phone, pd.status::text AS status, pd.joined_at \
         FROM partner_drivers pd JOIN users u ON u.id = pd.driver_user_id \
         WHERE pd.partner_id = $1 ORDER BY pd.joined_at DESC",
    )
    .bind(id)
    .fetch_all(&st.db)
    .await?;
    // Cross-service read against the merchant service's own table (shared
    // Postgres instance) — see `rides::routes::rides::get_participants`'s
    // identical reasoning for the equivalent merchant lookup there.
    let merchants: Vec<OwnedMerchant> = sqlx::query_as(
        "SELECT m.id, m.name, m.vertical, m.is_open FROM merchants m \
         WHERE m.owner_user_id IN (SELECT user_id FROM partner_members WHERE partner_id = $1) \
         ORDER BY m.name",
    )
    .bind(id)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(PartnerDetail {
        partner,
        member_count,
        driver_count,
        drivers,
        merchants,
    }))
}

#[derive(Deserialize)]
struct UpdatePartner {
    status: Option<String>,
    commission_share: Option<Decimal>,
    name: Option<String>,
    legal_name: Option<String>,
    #[serde(default)]
    partner_type: Option<String>,
    city: Option<String>,
    contact_phone: Option<String>,
    contact_email: Option<String>,
    pan_vat: Option<String>,
}

async fn update(
    State(st): State<AppState>,
    AdminUser(claims): AdminUser,
    Path(id): Path<Uuid>,
    Json(body): Json<UpdatePartner>,
) -> AppResult<Json<Partner>> {
    if let Some(s) = &body.status
        && !matches!(
            s.as_str(),
            "pending" | "active" | "suspended" | "terminated"
        )
    {
        return Err(AppError::BadRequest("invalid status".into()));
    }
    if let Some(t) = &body.partner_type
        && !matches!(t.as_str(), "fleet" | "corporate" | "agent")
    {
        return Err(AppError::BadRequest(
            "partner_type must be 'fleet', 'corporate', or 'agent'".into(),
        ));
    }
    if body.name.as_deref().is_some_and(|s| s.trim().is_empty()) {
        return Err(AppError::BadRequest("name can't be blank".into()));
    }
    let share = body
        .commission_share
        .map(|s| s.max(Decimal::ZERO).min(MAX_COMMISSION_RATE));

    let partner: Partner = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "UPDATE partners SET \
            status = COALESCE($2::partner_status, status), \
            commission_share = COALESCE($3, commission_share), \
            name = COALESCE($4, name), \
            legal_name = COALESCE($5, legal_name), \
            type = COALESCE($6::partner_type, type), \
            city = COALESCE($7, city), \
            contact_phone = COALESCE($8, contact_phone), \
            contact_email = COALESCE($9, contact_email), \
            pan_vat = COALESCE($10, pan_vat), \
            updated_at = now() \
         WHERE id = $1 RETURNING {PARTNER_COLS}"
    )))
    .bind(id)
    .bind(body.status)
    .bind(share)
    .bind(body.name)
    .bind(body.legal_name)
    .bind(body.partner_type)
    .bind(body.city)
    .bind(body.contact_phone)
    .bind(body.contact_email)
    .bind(body.pan_vat)
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
