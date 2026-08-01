//! Partner-scoped fleet money + analytics + campaigns. Membership is resolved
//! from the shared DB (`partner_members`) — a caller may only touch a fleet they
//! belong to, and money/campaign actions require the right partner role.

use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use saarathi_core::api::ErrorCode;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/partner/{pid}/analytics", get(analytics))
        .route("/v1/partner/{pid}/wallet", get(wallet))
        .route("/v1/partner/{pid}/wallet/topup", post(topup))
        .route(
            "/v1/partner/{pid}/wallet/topup/confirm",
            post(confirm_topup),
        )
        .route("/v1/partner/{pid}/ledger", get(ledger))
        .route(
            "/v1/partner/{pid}/payouts",
            get(list_payouts).post(request_payout),
        )
        .route(
            "/v1/partner/{pid}/campaigns",
            get(list_campaigns).post(create_campaign),
        )
        .route(
            "/v1/partner/{pid}/campaigns/{id}/deactivate",
            post(deactivate_campaign),
        )
}

/// The caller's active partner role, or 403 if not an active member of an active
/// partner.
async fn member_role(st: &AppState, user_id: Uuid, partner_id: Uuid) -> AppResult<String> {
    let row: Option<(String,)> = sqlx::query_as(
        "SELECT pm.role::text FROM partner_members pm JOIN partners p ON p.id = pm.partner_id \
         WHERE pm.partner_id = $1 AND pm.user_id = $2 AND pm.status = 'active' AND p.status = 'active'",
    )
    .bind(partner_id)
    .bind(user_id)
    .fetch_optional(&st.db)
    .await?;
    row.map(|r| r.0).ok_or(AppError::Forbidden)
}

async fn require_member(st: &AppState, user_id: Uuid, partner_id: Uuid) -> AppResult<()> {
    member_role(st, user_id, partner_id).await.map(|_| ())
}

/// Money actions: owner / admin / finance only.
fn can_manage_money(role: &str) -> bool {
    matches!(role, "owner" | "admin" | "finance")
}

/// Campaign actions: owner / admin / manager only.
fn can_manage_campaigns(role: &str) -> bool {
    matches!(role, "owner" | "admin" | "manager")
}

#[derive(sqlx::FromRow)]
struct FleetAgg {
    total: i64,
    completed: i64,
    cancelled: i64,
    gmv: Decimal,
    driver_earnings: Decimal,
}

async fn analytics(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
) -> AppResult<Json<Value>> {
    require_member(&st, claims.sub, pid).await?;

    let active_drivers: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM partner_drivers WHERE partner_id = $1 AND status = 'active'",
    )
    .bind(pid)
    .fetch_one(&st.db)
    .await?;

    // Trips flown by drivers currently in this fleet.
    let agg: FleetAgg = sqlx::query_as(
        "SELECT count(*) AS total, \
                count(*) FILTER (WHERE status = 'completed') AS completed, \
                count(*) FILTER (WHERE status = 'cancelled') AS cancelled, \
                coalesce(sum(gross_fare)   FILTER (WHERE status = 'completed'), 0) AS gmv, \
                coalesce(sum(driver_payout) FILTER (WHERE status = 'completed'), 0) AS driver_earnings \
         FROM trips \
         WHERE driver_id IN (SELECT driver_user_id FROM partner_drivers \
                             WHERE partner_id = $1 AND status = 'active')",
    )
    .bind(pid)
    .fetch_one(&st.db)
    .await?;

    // Per-driver leaderboard (top earners in the fleet).
    let leaders: Vec<(Uuid, Option<String>, i64, Decimal)> = sqlx::query_as(
        "SELECT t.driver_id, u.full_name, \
                count(*) FILTER (WHERE t.status = 'completed') AS trips, \
                coalesce(sum(t.driver_payout) FILTER (WHERE t.status = 'completed'), 0) AS earnings \
         FROM trips t JOIN users u ON u.id = t.driver_id \
         WHERE t.driver_id IN (SELECT driver_user_id FROM partner_drivers \
                               WHERE partner_id = $1 AND status = 'active') \
         GROUP BY t.driver_id, u.full_name ORDER BY earnings DESC LIMIT 10",
    )
    .bind(pid)
    .fetch_all(&st.db)
    .await?;

    let leaderboard: Vec<Value> = leaders
        .into_iter()
        .map(|(id, name, trips, earnings)| {
            json!({ "driver_id": id, "name": name, "trips": trips, "earnings": earnings })
        })
        .collect();

    Ok(Json(json!({
        "active_drivers": active_drivers,
        "trips": { "total": agg.total, "completed": agg.completed, "cancelled": agg.cancelled },
        "money": { "gmv": agg.gmv, "driver_earnings": agg.driver_earnings, "currency": "NPR" },
        "leaderboard": leaderboard,
    })))
}

// ── Fleet wallet + revenue-share ledger ─────────────────────────────────────

#[derive(Serialize, sqlx::FromRow)]
struct LedgerRow {
    kind: String,
    amount: Decimal,
    balance_after: Decimal,
    trip_id: Option<Uuid>,
    created_at: DateTime<Utc>,
}

async fn wallet(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
) -> AppResult<Json<Value>> {
    require_member(&st, claims.sub, pid).await?;
    let bal = crate::partner_ledger::balance(&st.db, pid).await?;
    let earned: Decimal = sqlx::query_scalar(
        "SELECT coalesce(sum(amount), 0) FROM partner_ledger WHERE partner_id = $1 AND kind = 'commission_share'",
    )
    .bind(pid)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({
        "balance": bal,
        "lifetime_share": earned,
        "currency": "NPR",
    })))
}

async fn ledger(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
) -> AppResult<Json<Vec<LedgerRow>>> {
    require_member(&st, claims.sub, pid).await?;
    let rows: Vec<LedgerRow> = sqlx::query_as(
        "SELECT kind, amount, balance_after, trip_id, created_at \
         FROM partner_ledger WHERE partner_id = $1 ORDER BY seq DESC LIMIT 100",
    )
    .bind(pid)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
struct TopupBody {
    amount: Decimal,
}

async fn topup(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
    Json(body): Json<TopupBody>,
) -> AppResult<Json<Value>> {
    let role = member_role(&st, claims.sub, pid).await?;
    if !can_manage_money(&role) {
        return Err(AppError::Forbidden);
    }
    if body.amount <= Decimal::ZERO {
        return Err(AppError::bad(
            ErrorCode::AmountInvalid,
            "amount must be positive",
        ));
    }
    let reference = st.payments.start_topup(pid, body.amount);
    sqlx::query(
        "INSERT INTO partner_topup_intents (reference, partner_id, amount, provider) \
         VALUES ($1, $2, $3, $4)",
    )
    .bind(&reference)
    .bind(pid)
    .bind(body.amount)
    .bind(st.payments.name())
    .execute(&st.db)
    .await?;
    Ok(Json(json!({
        "reference": reference,
        "amount": body.amount,
        "checkout_url": format!("mock://pay/{reference}"),
    })))
}

#[derive(Deserialize)]
struct ConfirmBody {
    reference: String,
}

/// Simulated PSP callback confirming a partner top-up (idempotent).
async fn confirm_topup(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
    Json(body): Json<ConfirmBody>,
) -> AppResult<Json<Value>> {
    require_member(&st, claims.sub, pid).await?;
    let mut tx = st.db.begin().await?;
    let intent: Option<(Uuid, Decimal, String)> = sqlx::query_as(
        "SELECT partner_id, amount, status FROM partner_topup_intents WHERE reference = $1 FOR UPDATE",
    )
    .bind(&body.reference)
    .fetch_optional(&mut *tx)
    .await?;
    let (partner_id, amount, status) = intent.ok_or(AppError::NotFound)?;
    if partner_id != pid {
        return Err(AppError::Forbidden);
    }
    if status == "confirmed" {
        return Ok(Json(json!({ "confirmed": true, "idempotent": true })));
    }
    let balance = crate::partner_ledger::append(&mut tx, pid, None, "topup", amount).await?;
    sqlx::query(
        "UPDATE partner_topup_intents SET status = 'confirmed', confirmed_at = now() WHERE reference = $1",
    )
    .bind(&body.reference)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Json(json!({ "confirmed": true, "balance": balance })))
}

#[derive(Serialize, sqlx::FromRow)]
struct PayoutRow {
    id: Uuid,
    amount: Decimal,
    status: String,
    reference: Option<String>,
    created_at: DateTime<Utc>,
}

#[derive(Deserialize)]
struct PayoutBody {
    amount: Option<Decimal>,
}

async fn request_payout(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
    Json(body): Json<PayoutBody>,
) -> AppResult<Json<Value>> {
    let role = member_role(&st, claims.sub, pid).await?;
    if !can_manage_money(&role) {
        return Err(AppError::Forbidden);
    }
    let mut tx = st.db.begin().await?;
    let (available,): (Decimal,) = sqlx::query_as(
        "SELECT coalesce(balance, 0) FROM partner_wallets WHERE partner_id = $1 FOR UPDATE",
    )
    .bind(pid)
    .fetch_optional(&mut *tx)
    .await?
    .unwrap_or((Decimal::ZERO,));
    let amount = body.amount.unwrap_or(available);
    if amount <= Decimal::ZERO || amount > available {
        return Err(AppError::BadRequest(
            "amount exceeds available balance".into(),
        ));
    }
    let reference = st.payments.start_payout(pid, amount);
    let balance = crate::partner_ledger::append(&mut tx, pid, None, "payout", -amount).await?;
    sqlx::query(
        "INSERT INTO partner_payouts (partner_id, amount, status, reference, processed_at) \
         VALUES ($1, $2, 'paid', $3, now())",
    )
    .bind(pid)
    .bind(amount)
    .bind(&reference)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Json(
        json!({ "amount": amount, "reference": reference, "balance": balance }),
    ))
}

async fn list_payouts(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
) -> AppResult<Json<Vec<PayoutRow>>> {
    require_member(&st, claims.sub, pid).await?;
    let rows: Vec<PayoutRow> = sqlx::query_as(
        "SELECT id, amount, status, reference, created_at \
         FROM partner_payouts WHERE partner_id = $1 ORDER BY created_at DESC LIMIT 100",
    )
    .bind(pid)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

// ── Fleet campaigns (partner-funded, scoped to this fleet) ──────────────────

#[derive(Serialize, sqlx::FromRow)]
struct FleetCampaign {
    id: Uuid,
    code: String,
    title: String,
    kind: String,
    value: Decimal,
    max_discount: Option<Decimal>,
    active: bool,
    used_count: i32,
    created_at: DateTime<Utc>,
}

const FLEET_CAMPAIGN_COLS: &str =
    "id, code, title, kind::text AS kind, value, max_discount, active, used_count, created_at";

async fn list_campaigns(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
) -> AppResult<Json<Vec<FleetCampaign>>> {
    require_member(&st, claims.sub, pid).await?;
    let rows: Vec<FleetCampaign> = sqlx::query_as(&format!(
        "SELECT {FLEET_CAMPAIGN_COLS} FROM campaigns WHERE partner_id = $1 ORDER BY created_at DESC"
    ))
    .bind(pid)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
struct NewFleetCampaign {
    code: String,
    title: String,
    kind: String, // percent | flat
    value: Decimal,
    max_discount: Option<Decimal>,
    #[serde(default)]
    min_fare: Option<Decimal>,
}

/// Create a partner-funded driver-bonus campaign for this fleet. The bonus is
/// drawn from the fleet wallet (Phase 2: driver-side only; rider corporate tabs
/// are Phase 3).
async fn create_campaign(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(pid): Path<Uuid>,
    Json(body): Json<NewFleetCampaign>,
) -> AppResult<Json<FleetCampaign>> {
    let role = member_role(&st, claims.sub, pid).await?;
    if !can_manage_campaigns(&role) {
        return Err(AppError::Forbidden);
    }
    if !matches!(body.kind.as_str(), "percent" | "flat") {
        return Err(AppError::BadRequest(
            "kind must be 'percent' or 'flat'".into(),
        ));
    }
    if body.code.trim().is_empty() {
        return Err(AppError::BadRequest("code is required".into()));
    }
    let campaign: FleetCampaign = sqlx::query_as(&format!(
        "INSERT INTO campaigns (code, title, audience, kind, value, min_fare, max_discount, \
            partner_id, funded_by, created_by) \
         VALUES ($1,$2,'driver',$3::discount_kind,$4,$5,$6,$7,'partner',$8) \
         RETURNING {FLEET_CAMPAIGN_COLS}"
    ))
    .bind(body.code.trim())
    .bind(body.title)
    .bind(body.kind)
    .bind(body.value)
    .bind(body.min_fare.unwrap_or(Decimal::ZERO))
    .bind(body.max_discount)
    .bind(pid)
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await
    .map_err(|e| match e {
        sqlx::Error::Database(db) if db.is_unique_violation() => {
            AppError::conflict(ErrorCode::DuplicateCode, "that code already exists")
        }
        other => AppError::Db(other),
    })?;
    Ok(Json(campaign))
}

async fn deactivate_campaign(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path((pid, id)): Path<(Uuid, Uuid)>,
) -> AppResult<Json<Value>> {
    let role = member_role(&st, claims.sub, pid).await?;
    if !can_manage_campaigns(&role) {
        return Err(AppError::Forbidden);
    }
    let res = sqlx::query("UPDATE campaigns SET active = false WHERE id = $1 AND partner_id = $2")
        .bind(id)
        .bind(pid)
        .execute(&st.db)
        .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(Json(json!({ "ok": true })))
}
