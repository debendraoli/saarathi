//! Merchant CRUD, menu management, photo uploads, open/close, self-service
//! onboarding, and store offers.

use super::owns_or_staff;
use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::routes::zone;
use crate::state::AppState;
use axum::body::Bytes;
use axum::extract::{Multipart, Path, Query, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::IntoResponse;
use axum::Json;
use rust_decimal::Decimal;
use saarathi_core::api::ErrorCode;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

// ── Merchants + menu ─────────────────────────────────────────────────────────

#[derive(Serialize, sqlx::FromRow)]
pub(super) struct Merchant {
    id: Uuid,
    name: String,
    vertical: String,
    address: Option<String>,
    phone: Option<String>,
    lat: f64,
    lng: f64,
    prep_mins: i32,
    is_open: bool,
    rating: Decimal,
    image_key: Option<String>,
    distance_m: f64,
    /// Staff approval state: pending | approved | rejected. Not sensitive —
    /// the owner's own `my_merchants` view needs it to show pending/rejected
    /// stores, so it's simplest to include on every projection.
    status: String,
    rejection_reason: Option<String>,
}

#[derive(Serialize, sqlx::FromRow)]
pub(super) struct MenuItem {
    id: Uuid,
    merchant_id: Uuid,
    name: String,
    description: Option<String>,
    category: Option<String>,
    price: Decimal,
    is_available: bool,
    image_key: Option<String>,
}

#[derive(Deserialize)]
pub(super) struct MerchantQuery {
    vertical: Option<String>,
    lat: Option<f64>,
    lng: Option<f64>,
}

pub(super) async fn list_merchants(
    State(st): State<AppState>,
    _auth: AuthUser,
    Query(q): Query<MerchantQuery>,
) -> AppResult<Json<Vec<Merchant>>> {
    let lat = q.lat.unwrap_or(28.033);
    let lng = q.lng.unwrap_or(82.484);
    let rows: Vec<Merchant> = sqlx::query_as(
        "SELECT id, name, vertical, address, phone, lat, lng, prep_mins, is_open, rating, image_key, \
                status::text, rejection_reason, \
                ST_Distance(geog, ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography) AS distance_m \
         FROM merchants \
         WHERE is_open AND status = 'approved' AND ($3::text IS NULL OR vertical = $3) \
         ORDER BY distance_m ASC LIMIT 50",
    )
    .bind(lat)
    .bind(lng)
    .bind(q.vertical)
    .fetch_all(&st.db)
    .await?;

    // Visibility is bounded by each merchant's delivery geofence (Phase 2's H3
    // polyfill cache) — a merchant with no zone defined is unbounded/visible
    // everywhere, matching `is_point_in_zone`'s None-means-unset semantics.
    let mut visible = Vec::with_capacity(rows.len());
    for m in rows {
        let in_zone = zone::is_point_in_zone(&st, m.id, lat, lng)
            .await
            .map_err(AppError::Other)?;
        if in_zone != Some(false) {
            visible.push(m);
        }
    }
    Ok(Json(visible))
}

pub(super) async fn merchant_detail(
    State(st): State<AppState>,
    _auth: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let merchant: Merchant = sqlx::query_as(
        "SELECT id, name, vertical, address, phone, lat, lng, prep_mins, is_open, rating, image_key, \
                status::text, rejection_reason, \
                0::double precision AS distance_m FROM merchants WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(&st.db)
    .await?
    .ok_or(AppError::NotFound)?;

    let items: Vec<MenuItem> = sqlx::query_as(
        "SELECT id, merchant_id, name, description, category, price, is_available, image_key \
         FROM menu_items WHERE merchant_id = $1 AND is_available ORDER BY category, name",
    )
    .bind(id)
    .fetch_all(&st.db)
    .await?;

    Ok(Json(json!({ "merchant": merchant, "items": items })))
}

// ── Merchant-facing ──────────────────────────────────────────────────────────

pub(super) async fn my_merchants(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Vec<Merchant>>> {
    let rows: Vec<Merchant> = sqlx::query_as(
        "SELECT id, name, vertical, address, phone, lat, lng, prep_mins, is_open, rating, image_key, \
                status::text, rejection_reason, \
                0::double precision AS distance_m \
         FROM merchants WHERE ($2 OR owner_user_id = $1) ORDER BY name",
    )
    .bind(claims.sub)
    .bind(claims.is_staff())
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

/// Full menu (including unavailable items) for a merchant the caller manages.
pub(super) async fn merchant_menu(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Vec<MenuItem>>> {
    if !owns_or_staff(&st, claims.sub, claims.is_staff(), id).await? {
        return Err(AppError::Forbidden);
    }
    let items: Vec<MenuItem> = sqlx::query_as(
        "SELECT id, merchant_id, name, description, category, price, is_available, image_key \
         FROM menu_items WHERE merchant_id = $1 ORDER BY category, name",
    )
    .bind(id)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(items))
}

#[derive(Serialize, sqlx::FromRow)]
struct MerchantOverview {
    total_orders: i64,
    delivered_orders: i64,
    cancelled_orders: i64,
    total_revenue: Decimal,
    avg_order_value: Decimal,
}

#[derive(Serialize, sqlx::FromRow)]
struct TopItem {
    menu_item_id: Uuid,
    name: String,
    units: i64,
    revenue: Decimal,
}

#[derive(Serialize, sqlx::FromRow)]
struct RatingBucket {
    stars: i32,
    count: i64,
}

/// Owner-scoped store analytics — mirrors the aggregate-query shape of
/// `partners/src/routes/fleet.rs`'s `analytics()` (ownership check → one
/// overview aggregate → a GROUP BY leaderboard, here "top items" instead of
/// "top drivers").
pub(super) async fn merchant_analytics(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    if !owns_or_staff(&st, claims.sub, claims.is_staff(), id).await? {
        return Err(AppError::Forbidden);
    }

    let overview: MerchantOverview = sqlx::query_as(
        "SELECT count(*) AS total_orders, \
                count(*) FILTER (WHERE status = 'delivered') AS delivered_orders, \
                count(*) FILTER (WHERE status IN ('cancelled', 'rejected')) AS cancelled_orders, \
                COALESCE(SUM(total) FILTER (WHERE status = 'delivered'), 0) AS total_revenue, \
                COALESCE(AVG(total) FILTER (WHERE status = 'delivered'), 0) AS avg_order_value \
         FROM orders WHERE merchant_id = $1",
    )
    .bind(id)
    .fetch_one(&st.db)
    .await?;

    let today: MerchantOverview = sqlx::query_as(
        "SELECT count(*) AS total_orders, \
                count(*) FILTER (WHERE status = 'delivered') AS delivered_orders, \
                count(*) FILTER (WHERE status IN ('cancelled', 'rejected')) AS cancelled_orders, \
                COALESCE(SUM(total) FILTER (WHERE status = 'delivered'), 0) AS total_revenue, \
                COALESCE(AVG(total) FILTER (WHERE status = 'delivered'), 0) AS avg_order_value \
         FROM orders WHERE merchant_id = $1 AND created_at::date = current_date",
    )
    .bind(id)
    .fetch_one(&st.db)
    .await?;

    let top_items: Vec<TopItem> = sqlx::query_as(
        "SELECT oi.menu_item_id, oi.name, SUM(oi.qty)::bigint AS units, \
                SUM(oi.qty * oi.unit_price) AS revenue \
         FROM order_items oi JOIN orders o ON o.id = oi.order_id \
         WHERE o.merchant_id = $1 AND o.status = 'delivered' \
         GROUP BY oi.menu_item_id, oi.name ORDER BY units DESC LIMIT 10",
    )
    .bind(id)
    .fetch_all(&st.db)
    .await?;

    let rating_breakdown: Vec<RatingBucket> = sqlx::query_as(
        "SELECT stars, count(*) FROM merchant_ratings WHERE merchant_id = $1 \
         GROUP BY stars ORDER BY stars DESC",
    )
    .bind(id)
    .fetch_all(&st.db)
    .await?;

    Ok(Json(json!({
        "overview": overview,
        "today": today,
        "top_items": top_items,
        "rating_breakdown": rating_breakdown,
    })))
}

// ── Store offers (self-service, owner-configured) ──────────────────────────

const OFFER_COLS: &str = "id, merchant_id, kind, value, max_discount, min_order_amount, \
    starts_at, ends_at, daily_start_minute, daily_end_minute, active, created_at";

#[derive(Serialize, sqlx::FromRow)]
pub(super) struct MerchantOffer {
    id: Uuid,
    merchant_id: Uuid,
    kind: String,
    value: Option<Decimal>,
    max_discount: Option<Decimal>,
    min_order_amount: Decimal,
    starts_at: Option<chrono::DateTime<chrono::Utc>>,
    ends_at: Option<chrono::DateTime<chrono::Utc>>,
    daily_start_minute: Option<i32>,
    daily_end_minute: Option<i32>,
    active: bool,
    created_at: chrono::DateTime<chrono::Utc>,
}

pub(super) async fn list_offers(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Vec<MerchantOffer>>> {
    if !owns_or_staff(&st, claims.sub, claims.is_staff(), id).await? {
        return Err(AppError::Forbidden);
    }
    let rows: Vec<MerchantOffer> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {OFFER_COLS} FROM merchant_offers WHERE merchant_id = $1 ORDER BY created_at DESC"
    )))
    .bind(id)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

/// Active, in-window offers for the customer-facing banner — no ownership
/// check, any signed-in user browsing/ordering from this store can see them.
pub(super) async fn active_offers(
    State(st): State<AppState>,
    _auth: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Vec<MerchantOffer>>> {
    let rows: Vec<MerchantOffer> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {OFFER_COLS} FROM merchant_offers \
         WHERE merchant_id = $1 AND active = true \
           AND (starts_at IS NULL OR starts_at <= now()) \
           AND (ends_at IS NULL OR ends_at >= now()) \
         ORDER BY created_at DESC"
    )))
    .bind(id)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
pub(super) struct NearbyOffersQuery {
    vertical: Option<String>,
    lat: Option<f64>,
    lng: Option<f64>,
}

#[derive(Serialize, sqlx::FromRow)]
pub(super) struct NearbyOffer {
    id: Uuid,
    merchant_id: Uuid,
    merchant_name: String,
    vertical: String,
    image_key: Option<String>,
    kind: String,
    value: Option<Decimal>,
    max_discount: Option<Decimal>,
    min_order_amount: Decimal,
    distance_m: f64,
}

/// Active, in-window offers across nearby open merchants — the "Offers near
/// you" rail on the browse screen. Same visibility rules as [list_merchants]
/// (open, approved, in the merchant's delivery zone if it has one).
pub(super) async fn nearby_offers(
    State(st): State<AppState>,
    _auth: AuthUser,
    Query(q): Query<NearbyOffersQuery>,
) -> AppResult<Json<Vec<NearbyOffer>>> {
    let lat = q.lat.unwrap_or(28.033);
    let lng = q.lng.unwrap_or(82.484);
    let rows: Vec<NearbyOffer> = sqlx::query_as(
        "SELECT o.id, m.id AS merchant_id, m.name AS merchant_name, m.vertical, \
                m.image_key, o.kind, o.value, o.max_discount, o.min_order_amount, \
                ST_Distance(m.geog, ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography) AS distance_m \
         FROM merchant_offers o \
         JOIN merchants m ON m.id = o.merchant_id \
         WHERE o.active = true \
           AND (o.starts_at IS NULL OR o.starts_at <= now()) \
           AND (o.ends_at IS NULL OR o.ends_at >= now()) \
           AND m.is_open AND m.status = 'approved' \
           AND ($3::text IS NULL OR m.vertical = $3) \
         ORDER BY distance_m ASC LIMIT 20",
    )
    .bind(lat)
    .bind(lng)
    .bind(q.vertical)
    .fetch_all(&st.db)
    .await?;

    let mut visible = Vec::with_capacity(rows.len());
    for o in rows {
        let in_zone = zone::is_point_in_zone(&st, o.merchant_id, lat, lng)
            .await
            .map_err(AppError::Other)?;
        if in_zone != Some(false) {
            visible.push(o);
        }
    }
    Ok(Json(visible))
}

#[derive(Deserialize)]
pub(super) struct NewOffer {
    kind: String, // free_delivery | percent | flat
    value: Option<Decimal>,
    max_discount: Option<Decimal>,
    #[serde(default)]
    min_order_amount: Option<Decimal>,
    starts_at: Option<chrono::DateTime<chrono::Utc>>,
    ends_at: Option<chrono::DateTime<chrono::Utc>>,
    daily_start_minute: Option<i32>,
    daily_end_minute: Option<i32>,
}

pub(super) async fn create_offer(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
    Json(body): Json<NewOffer>,
) -> AppResult<Json<MerchantOffer>> {
    if !owns_or_staff(&st, claims.sub, claims.is_staff(), id).await? {
        return Err(AppError::Forbidden);
    }
    if !matches!(body.kind.as_str(), "free_delivery" | "percent" | "flat") {
        return Err(AppError::BadRequest(
            "kind must be 'free_delivery', 'percent', or 'flat'".into(),
        ));
    }
    if body.kind != "free_delivery" && body.value.is_none() {
        return Err(AppError::BadRequest(
            "value is required for a percent/flat offer".into(),
        ));
    }
    if body.kind == "percent" {
        let v = body.value.unwrap_or_default();
        if v <= Decimal::ZERO || v > Decimal::from(100) {
            return Err(AppError::BadRequest(
                "percent value must be between 0 and 100".into(),
            ));
        }
    }
    if body.daily_start_minute.is_some() != body.daily_end_minute.is_some() {
        return Err(AppError::BadRequest(
            "daily_start_minute and daily_end_minute must be set together".into(),
        ));
    }

    let offer: MerchantOffer = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "INSERT INTO merchant_offers (merchant_id, kind, value, max_discount, min_order_amount, \
            starts_at, ends_at, daily_start_minute, daily_end_minute) \
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING {OFFER_COLS}"
    )))
    .bind(id)
    .bind(&body.kind)
    .bind(body.value)
    .bind(body.max_discount)
    .bind(body.min_order_amount.unwrap_or(Decimal::ZERO))
    .bind(body.starts_at)
    .bind(body.ends_at)
    .bind(body.daily_start_minute)
    .bind(body.daily_end_minute)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(offer))
}

pub(super) async fn deactivate_offer(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path((id, offer_id)): Path<(Uuid, Uuid)>,
) -> AppResult<Json<Value>> {
    if !owns_or_staff(&st, claims.sub, claims.is_staff(), id).await? {
        return Err(AppError::Forbidden);
    }
    let res =
        sqlx::query("UPDATE merchant_offers SET active = false WHERE id = $1 AND merchant_id = $2")
            .bind(offer_id)
            .bind(id)
            .execute(&st.db)
            .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(Json(json!({ "ok": true })))
}

#[derive(Deserialize)]
pub(super) struct SetAvailable {
    is_available: bool,
}

pub(super) async fn set_item_availability(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(item_id): Path<Uuid>,
    Json(body): Json<SetAvailable>,
) -> AppResult<Json<Value>> {
    let merchant_id: Uuid = sqlx::query_scalar("SELECT merchant_id FROM menu_items WHERE id = $1")
        .bind(item_id)
        .fetch_optional(&st.db)
        .await?
        .ok_or(AppError::NotFound)?;
    if !owns_or_staff(&st, claims.sub, claims.is_staff(), merchant_id).await? {
        return Err(AppError::Forbidden);
    }
    sqlx::query("UPDATE menu_items SET is_available = $2 WHERE id = $1")
        .bind(item_id)
        .bind(body.is_available)
        .execute(&st.db)
        .await?;
    Ok(Json(
        json!({ "ok": true, "is_available": body.is_available }),
    ))
}

#[derive(Deserialize)]
pub(super) struct AddItem {
    merchant_id: Uuid,
    name: String,
    price: Decimal,
    category: Option<String>,
    description: Option<String>,
}

pub(super) async fn add_menu_item(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<AddItem>,
) -> AppResult<Json<Value>> {
    if !owns_or_staff(&st, claims.sub, claims.is_staff(), body.merchant_id).await? {
        return Err(AppError::Forbidden);
    }
    let id: Uuid = sqlx::query_scalar(
        "INSERT INTO menu_items (merchant_id, name, price, category, description) \
         VALUES ($1,$2,$3,$4,$5) RETURNING id",
    )
    .bind(body.merchant_id)
    .bind(body.name.trim())
    .bind(body.price)
    .bind(body.category)
    .bind(body.description)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({ "id": id })))
}

/// Pulls the single `photo` field out of a multipart body. Shared by both the
/// shop-photo and item-photo uploads below.
async fn read_photo_field(mut multipart: Multipart) -> AppResult<Vec<u8>> {
    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| AppError::BadRequest(e.to_string()))?
    {
        if field.name() == Some("photo") {
            let data = field
                .bytes()
                .await
                .map_err(|e| AppError::BadRequest(e.to_string()))?;
            if data.is_empty() {
                return Err(AppError::BadRequest("empty photo".into()));
            }
            return Ok(data.to_vec());
        }
    }
    Err(AppError::BadRequest("missing 'photo' field".into()))
}

pub(super) async fn upload_item_photo(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
    multipart: Multipart,
) -> AppResult<Json<Value>> {
    let merchant_id: Uuid = sqlx::query_scalar("SELECT merchant_id FROM menu_items WHERE id = $1")
        .bind(id)
        .fetch_optional(&st.db)
        .await?
        .ok_or(AppError::NotFound)?;
    if !owns_or_staff(&st, claims.sub, claims.is_staff(), merchant_id).await? {
        return Err(AppError::Forbidden);
    }
    let bytes = read_photo_field(multipart).await?;
    let key = format!("items/{id}/{}", Uuid::new_v4());
    st.docs.put(&key, bytes).await.map_err(AppError::Other)?;
    sqlx::query("UPDATE menu_items SET photo_storage_key = $2, image_key = $3 WHERE id = $1")
        .bind(id)
        .bind(&key)
        .bind(format!("/v1/items/{id}/photo"))
        .execute(&st.db)
        .await?;
    Ok(Json(json!({ "ok": true })))
}

pub(super) async fn upload_merchant_photo(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
    multipart: Multipart,
) -> AppResult<Json<Value>> {
    if !owns_or_staff(&st, claims.sub, claims.is_staff(), id).await? {
        return Err(AppError::Forbidden);
    }
    let bytes = read_photo_field(multipart).await?;
    let key = format!("merchants/{id}/{}", Uuid::new_v4());
    st.docs.put(&key, bytes).await.map_err(AppError::Other)?;
    sqlx::query("UPDATE merchants SET photo_storage_key = $2, image_key = $3 WHERE id = $1")
        .bind(id)
        .bind(&key)
        .bind(format!("/v1/merchants/{id}/photo"))
        .execute(&st.db)
        .await?;
    Ok(Json(json!({ "ok": true })))
}

pub(super) async fn merchant_photo(
    State(st): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<impl IntoResponse> {
    let key: Option<String> =
        sqlx::query_scalar("SELECT photo_storage_key FROM merchants WHERE id = $1")
            .bind(id)
            .fetch_optional(&st.db)
            .await?
            .flatten();
    let key = key.ok_or(AppError::NotFound)?;
    let bytes = st.docs.get(&key).await.map_err(AppError::Other)?;
    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        "application/octet-stream".parse().unwrap(),
    );
    Ok((StatusCode::OK, headers, Bytes::from(bytes)))
}

#[derive(Deserialize)]
pub(super) struct SetOpen {
    merchant_id: Uuid,
    is_open: bool,
}

pub(super) async fn set_open(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<SetOpen>,
) -> AppResult<Json<Value>> {
    if !owns_or_staff(&st, claims.sub, claims.is_staff(), body.merchant_id).await? {
        return Err(AppError::Forbidden);
    }
    if body.is_open {
        let status: Option<String> =
            sqlx::query_scalar("SELECT status::text FROM merchants WHERE id = $1")
                .bind(body.merchant_id)
                .fetch_optional(&st.db)
                .await?;
        if status.as_deref() != Some("approved") {
            return Err(AppError::BadRequest(
                "store must be approved before it can open for business".into(),
            ));
        }
    }
    sqlx::query("UPDATE merchants SET is_open = $2 WHERE id = $1")
        .bind(body.merchant_id)
        .bind(body.is_open)
        .execute(&st.db)
        .await?;
    Ok(Json(json!({ "ok": true, "is_open": body.is_open })))
}

#[derive(Deserialize)]
pub(super) struct MerchantApply {
    name: String,
    vertical: String,
    address: Option<String>,
    phone: Option<String>,
    pan_vat: Option<String>,
    lat: f64,
    lng: f64,
}

/// Self-service store registration: creates a merchant owned by the caller,
/// closed until they open it. Tax id (PAN/VAT) captured for compliance.
pub(super) async fn apply_merchant(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<MerchantApply>,
) -> AppResult<Json<Value>> {
    if !matches!(body.vertical.as_str(), "food" | "grocery") {
        return Err(AppError::BadRequest(
            "vertical must be 'food' or 'grocery'".into(),
        ));
    }
    if body.name.trim().is_empty() {
        return Err(AppError::BadRequest("name is required".into()));
    }
    // One store per registration: a prior rejection doesn't hold the slot,
    // but a pending or approved store does — backed by
    // merchants_one_active_per_owner_idx.
    let existing: Option<Uuid> = sqlx::query_scalar(
        "SELECT id FROM merchants WHERE owner_user_id = $1 AND status <> 'rejected'",
    )
    .bind(claims.sub)
    .fetch_optional(&st.db)
    .await?;
    if existing.is_some() {
        return Err(AppError::Coded(
            StatusCode::CONFLICT,
            ErrorCode::Conflict,
            "you already have a registered store".into(),
        ));
    }
    let id: Uuid = sqlx::query_scalar(
        "INSERT INTO merchants \
             (owner_user_id, name, vertical, address, phone, pan_vat, lat, lng, is_open, prep_mins) \
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,false,20) RETURNING id",
    )
    .bind(claims.sub)
    .bind(body.name.trim())
    .bind(&body.vertical)
    .bind(body.address)
    .bind(body.phone)
    .bind(body.pan_vat)
    .bind(body.lat)
    .bind(body.lng)
    .fetch_one(&st.db)
    .await?;

    crate::notify::send(
        &st.nats,
        claims.sub,
        saarathi_core::domain::notif::TRANSACTIONAL,
        "Store registered",
        "Your store is set up. Add your menu and open when you're ready to take orders.",
        Some("saarathi://merchant/dashboard".to_string()),
    )
    .await;

    Ok(Json(json!({ "id": id })))
}
