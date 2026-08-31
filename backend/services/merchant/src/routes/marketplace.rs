//! Marketplace (food / grocery): merchants, menus, and customer orders. An
//! order's courier leg reuses delivery — when it's marked `ready` we call
//! rides' internal `/v1/internal/delivery-trips` API (not the gateway; see
//! that endpoint's docs) so the existing dispatch + settlement plumbing
//! carries it to the customer, without this service reaching into rides'
//! internals directly.

use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::routes::zone;
use crate::state::AppState;
use axum::body::Bytes;
use axum::extract::{Multipart, Path, Query, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::{
    routing::{get, post},
    Json, Router,
};
use rust_decimal::Decimal;
use saarathi_core::api::ErrorCode;
use saarathi_core::idempotency::{self, Reservation};
use saarathi_core::routing::{LatLng, RouteProfile};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/merchants", get(list_merchants))
        .route("/v1/merchants/{id}", get(merchant_detail))
        .route("/v1/items/search", get(search_items))
        .route("/v1/orders", get(my_orders).post(place_order))
        .route("/v1/orders/mine/stats", get(my_order_stats))
        .route("/v1/orders/{id}", get(order_detail))
        .route("/v1/orders/{id}/status", post(update_order_status))
        .route("/v1/orders/{id}/rate", post(rate_merchant))
        // Merchant-facing (owner of the merchant, or staff).
        .route("/v1/merchant/merchants", get(my_merchants))
        .route("/v1/merchant/merchants/{id}/menu", get(merchant_menu))
        .route(
            "/v1/merchant/merchants/{id}/analytics",
            get(merchant_analytics),
        )
        .route(
            "/v1/merchant/merchants/{id}/offers",
            get(list_offers).post(create_offer),
        )
        .route(
            "/v1/merchant/merchants/{id}/offers/{offer_id}/deactivate",
            post(deactivate_offer),
        )
        .route("/v1/merchants/{id}/offers/active", get(active_offers))
        .route("/v1/offers/nearby", get(nearby_offers))
        .route("/v1/merchant/orders", get(merchant_orders))
        .route("/v1/merchant/menu", post(add_menu_item))
        .route(
            "/v1/merchant/menu/{id}/availability",
            post(set_item_availability),
        )
        .route("/v1/merchant/menu/{id}/photo", post(upload_item_photo))
        .route("/v1/items/{id}/photo", get(item_photo))
        .route(
            "/v1/merchant/merchants/{id}/photo",
            post(upload_merchant_photo),
        )
        .route("/v1/merchants/{id}/photo", get(merchant_photo))
        .route("/v1/merchant/open", post(set_open))
        // Self-service onboarding (any signed-in user can register a store).
        .route("/v1/merchant/apply", post(apply_merchant))
        // Ops onboarding.
        .route("/v1/admin/merchants", post(create_merchant))
        // Staff review queue.
        .route("/v1/admin/merchants/queue", get(merchant_queue))
        .route("/v1/admin/merchants/{id}/approve", post(approve_merchant))
        .route("/v1/admin/merchants/{id}/reject", post(reject_merchant))
        .route(
            "/v1/admin/merchants/{id}",
            axum::routing::patch(update_merchant),
        )
}

/// True when the user owns the merchant (or is staff).
pub(crate) async fn owns_or_staff(
    st: &AppState,
    uid: Uuid,
    is_staff: bool,
    merchant_id: Uuid,
) -> AppResult<bool> {
    if is_staff {
        return Ok(true);
    }
    let owner: Option<Option<Uuid>> =
        sqlx::query_scalar("SELECT owner_user_id FROM merchants WHERE id = $1")
            .bind(merchant_id)
            .fetch_optional(&st.db)
            .await?;
    Ok(matches!(owner, Some(Some(o)) if o == uid))
}

// ── Merchants + menu ─────────────────────────────────────────────────────────

#[derive(Serialize, sqlx::FromRow)]
struct Merchant {
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
struct MenuItem {
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
struct MerchantQuery {
    vertical: Option<String>,
    lat: Option<f64>,
    lng: Option<f64>,
}

async fn list_merchants(
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

// ── Cross-merchant item search ───────────────────────────────────────────────

#[derive(Deserialize)]
struct ItemSearchQuery {
    q: String,
    lat: Option<f64>,
    lng: Option<f64>,
    vertical: Option<String>,
    /// nearest (default) | cheapest | rating
    sort: Option<String>,
}

#[derive(Serialize, sqlx::FromRow)]
struct ItemHit {
    id: Uuid,
    merchant_id: Uuid,
    merchant_name: String,
    vertical: String,
    name: String,
    description: Option<String>,
    category: Option<String>,
    price: Decimal,
    image_key: Option<String>,
    rating: Decimal,
    distance_m: f64,
}

/// Search available items across all open merchants, sorted by nearest /
/// cheapest / top-rated.
async fn search_items(
    State(st): State<AppState>,
    _auth: AuthUser,
    Query(q): Query<ItemSearchQuery>,
) -> AppResult<Json<Vec<ItemHit>>> {
    let term = q.q.trim();
    if term.chars().count() < 2 {
        return Ok(Json(vec![]));
    }
    let lat = q.lat.unwrap_or(28.033);
    let lng = q.lng.unwrap_or(82.484);
    // Whitelisted sort — never interpolate user input into SQL.
    let order = match q.sort.as_deref() {
        Some("cheapest") => "mi.price ASC, distance_m ASC",
        Some("rating") => "m.rating DESC, distance_m ASC",
        _ => "distance_m ASC",
    };
    let sql = format!(
        "SELECT mi.id, mi.merchant_id, m.name AS merchant_name, m.vertical, mi.name, \
                mi.description, mi.category, mi.price, mi.image_key, m.rating, \
                ST_Distance(m.geog, ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography) AS distance_m \
         FROM menu_items mi JOIN merchants m ON m.id = mi.merchant_id \
         WHERE mi.is_available AND m.is_open AND m.status = 'approved' AND mi.name ILIKE $3 \
               AND ($4::text IS NULL OR m.vertical = $4) \
         ORDER BY {order} LIMIT 40"
    );
    let rows: Vec<ItemHit> = sqlx::query_as(sqlx::AssertSqlSafe(sql))
        .bind(lat)
        .bind(lng)
        .bind(format!("%{term}%"))
        .bind(q.vertical)
        .fetch_all(&st.db)
        .await?;
    Ok(Json(rows))
}

async fn merchant_detail(
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

// ── Orders ───────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct OrderLine {
    menu_item_id: Uuid,
    qty: i32,
}

#[derive(Deserialize)]
struct PlaceOrder {
    merchant_id: Uuid,
    items: Vec<OrderLine>,
    delivery: LatLng,
    delivery_note: Option<String>,
    #[serde(default)]
    payment_method: Option<String>,
}

async fn place_order(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    headers: HeaderMap,
    Json(body): Json<PlaceOrder>,
) -> AppResult<Json<Value>> {
    // A dropped response (flaky network) shouldn't turn one tap of "place
    // order" into two orders — same idempotency-key protocol as rides/payments.
    let idem_key = headers
        .get("x-idempotency-key")
        .and_then(|v| v.to_str().ok())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            AppError::BadRequest("X-Idempotency-Key header is required".into())
        })?
        .to_string();
    let mut reserve_tx = st.db.begin().await?;
    let reservation = idempotency::reserve(&mut reserve_tx, &idem_key, claims.sub, "marketplace.place_order")
        .await
        .map_err(anyhow::Error::from)
        .map_err(AppError::Other)?;
    reserve_tx.commit().await?;
    if let Reservation::Replay { body, .. } = reservation {
        let order_id: Uuid = serde_json::from_value(body["id"].clone())
            .map_err(|e| AppError::Other(e.into()))?;
        return order_json(&st, order_id, claims.sub, false).await;
    }

    if body.items.is_empty() {
        return Err(AppError::BadRequest("order has no items".into()));
    }
    let method = body.payment_method.as_deref().unwrap_or("cash");
    if !matches!(method, "cash" | "wallet") {
        return Err(AppError::BadRequest(
            "payment_method must be 'cash' or 'wallet'".into(),
        ));
    }

    let merchant: (f64, f64, bool) =
        sqlx::query_as("SELECT lat, lng, is_open FROM merchants WHERE id = $1")
            .bind(body.merchant_id)
            .fetch_optional(&st.db)
            .await?
            .ok_or(AppError::NotFound)?;
    if !merchant.2 {
        return Err(AppError::BadRequest("merchant is closed".into()));
    }
    let in_zone = zone::is_point_in_zone(&st, body.merchant_id, body.delivery.lat, body.delivery.lng)
        .await
        .map_err(AppError::Other)?;
    if in_zone == Some(false) {
        return Err(AppError::BadRequest(
            "delivery address is outside this merchant's delivery zone".into(),
        ));
    }

    // Price from the DB — never trust client-supplied prices.
    let mut subtotal = Decimal::ZERO;
    let mut priced: Vec<(Uuid, String, Decimal, i32)> = Vec::new();
    for line in &body.items {
        if line.qty <= 0 {
            return Err(AppError::BadRequest("item qty must be positive".into()));
        }
        let item: Option<(String, Decimal)> = sqlx::query_as(
            "SELECT name, price FROM menu_items \
             WHERE id = $1 AND merchant_id = $2 AND is_available",
        )
        .bind(line.menu_item_id)
        .bind(body.merchant_id)
        .fetch_optional(&st.db)
        .await?;
        let (name, price) = item.ok_or_else(|| {
            AppError::BadRequest("an item is unavailable or not on this menu".into())
        })?;
        subtotal += price * Decimal::from(line.qty);
        priced.push((line.menu_item_id, name, price, line.qty));
    }

    // Delivery fee from merchant → customer distance (config-driven).
    let route = st
        .router
        .route_path(
            &[
                LatLng {
                    lat: merchant.0,
                    lng: merchant.1,
                },
                body.delivery,
            ],
            RouteProfile::Motorcycle,
        )
        .await;
    let mut delivery_fee =
        (st.config.delivery_base_fare + route.distance_km * st.config.delivery_per_km).round_dp(2);

    // At most one store offer auto-applies, whichever saves the most —
    // no code to enter, same "just show it, don't make them type it"
    // philosophy as the rider ride-discount auto-apply.
    let mut discount_amount = Decimal::ZERO;
    let mut offer_id: Option<Uuid> = None;
    if let Some((oid, kind, savings)) =
        best_matching_offer(&st, body.merchant_id, subtotal, delivery_fee).await
    {
        offer_id = Some(oid);
        if kind == "free_delivery" {
            delivery_fee = Decimal::ZERO;
        } else {
            discount_amount = savings;
        }
    }
    let total = order_total(subtotal, discount_amount, delivery_fee);

    let mut tx = st.db.begin().await?;
    let order_id: Uuid = sqlx::query_scalar(
        "INSERT INTO orders (customer_id, merchant_id, subtotal, delivery_fee, total, \
            discount_amount, offer_id, payment_method, delivery_lat, delivery_lng, delivery_note) \
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) RETURNING id",
    )
    .bind(claims.sub)
    .bind(body.merchant_id)
    .bind(subtotal)
    .bind(delivery_fee)
    .bind(total)
    .bind(discount_amount)
    .bind(offer_id)
    .bind(method)
    .bind(body.delivery.lat)
    .bind(body.delivery.lng)
    .bind(body.delivery_note.as_deref())
    .fetch_one(&mut *tx)
    .await?;

    for (item_id, name, price, qty) in &priced {
        sqlx::query(
            "INSERT INTO order_items (order_id, menu_item_id, name, unit_price, qty) \
             VALUES ($1,$2,$3,$4,$5)",
        )
        .bind(order_id)
        .bind(item_id)
        .bind(name)
        .bind(price)
        .bind(qty)
        .execute(&mut *tx)
        .await?;
    }

    // Wallet orders actually charge here, atomically with order creation —
    // cash orders settle physically on delivery, nothing to move now.
    if method == "wallet" {
        saarathi_core::wallet::debit_rider(&mut tx, claims.sub, total, "order_charge", Some(order_id))
            .await?;
    }

    idempotency::store(
        &mut tx,
        &idem_key,
        claims.sub,
        "marketplace.place_order",
        200,
        &json!({ "id": order_id }),
    )
    .await
    .map_err(anyhow::Error::from)
    .map_err(AppError::Other)?;
    tx.commit().await?;

    let owner_id: Option<Uuid> = sqlx::query_scalar("SELECT owner_user_id FROM merchants WHERE id = $1")
        .bind(body.merchant_id)
        .fetch_one(&st.db)
        .await?;
    if let Some(owner_id) = owner_id {
        crate::notify::send(
            &st.nats,
            owner_id,
            saarathi_core::domain::notif::TRANSACTIONAL,
            "New order arrived",
            &format!("A new order (NPR {}) just came in.", total.round_dp(0)),
            Some(format!("saarathi://order/{order_id}")),
        )
        .await;
    }

    order_json(&st, order_id, claims.sub, false).await
}

/// Offset pagination for a list endpoint — same shape/reasoning as every
/// other service's own small copy of this (e.g. `rides::routes::rides`'s
/// `PageQuery`); not worth a shared crate for a few lines.
#[derive(Deserialize)]
struct PageQuery {
    #[serde(default)]
    limit: Option<i64>,
    #[serde(default)]
    offset: Option<i64>,
}

impl PageQuery {
    fn limit(&self) -> i64 {
        self.limit.unwrap_or(20).clamp(1, 100)
    }
    fn offset(&self) -> i64 {
        self.offset.unwrap_or(0).max(0)
    }
}

async fn my_orders(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Query(page): Query<PageQuery>,
) -> AppResult<Json<Value>> {
    let rows: Vec<OrderRow> = sqlx::query_as(
        "SELECT o.id, o.customer_id, o.merchant_id, m.name AS merchant_name, o.status, o.subtotal, \
                o.delivery_fee, o.total, o.discount_amount, o.payment_method, o.delivery_lat, o.delivery_lng, \
                o.trip_id, o.created_at \
         FROM orders o JOIN merchants m ON m.id = o.merchant_id \
         WHERE o.customer_id = $1 ORDER BY o.created_at DESC LIMIT $2 OFFSET $3",
    )
    .bind(claims.sub)
    .bind(page.limit())
    .bind(page.offset())
    .fetch_all(&st.db)
    .await?;

    // Whether *this caller* already rated each order's courier — read
    // directly against the rides service's own `ratings` table (shared
    // Postgres instance, same established cross-service-read convention
    // already used elsewhere, e.g. delivery-trip visibility). Only orders
    // with a dispatched courier (trip_id set) can be rated at all.
    let trip_ids: Vec<Uuid> = rows.iter().filter_map(|o| o.trip_id).collect();
    let rated_ids: Vec<Uuid> =
        sqlx::query_scalar("SELECT trip_id FROM ratings WHERE rater_id = $1 AND trip_id = ANY($2)")
            .bind(claims.sub)
            .bind(&trip_ids)
            .fetch_all(&st.db)
            .await?;

    // Whether the caller already rated the merchant itself — every order
    // (not just ones with a courier) is eligible once delivered.
    let order_ids: Vec<Uuid> = rows.iter().map(|o| o.id).collect();
    let merchant_rated_ids: Vec<Uuid> = sqlx::query_scalar(
        "SELECT order_id FROM merchant_ratings WHERE rater_id = $1 AND order_id = ANY($2)",
    )
    .bind(claims.sub)
    .bind(&order_ids)
    .fetch_all(&st.db)
    .await?;

    let out: Vec<Value> = rows
        .into_iter()
        .map(|o| {
            let rated = o.trip_id.is_some_and(|id| rated_ids.contains(&id));
            let merchant_rated = merchant_rated_ids.contains(&o.id);
            let mut v = serde_json::to_value(o).unwrap_or_default();
            v["rated"] = json!(rated);
            v["merchant_rated"] = json!(merchant_rated);
            v
        })
        .collect();
    Ok(Json(json!(out)))
}

/// Self-service order-spend rollup for the rider stats screen — mirrors
/// `saarathi-rides`' `GET /v1/rides/mine/stats` in shape.
async fn my_order_stats(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Value>> {
    let (total_orders, delivered_orders, total_spent): (i64, i64, Decimal) = sqlx::query_as(
        "SELECT count(*), \
                count(*) FILTER (WHERE status = 'delivered'), \
                COALESCE(SUM(total) FILTER (WHERE status = 'delivered'), 0) \
         FROM orders WHERE customer_id = $1",
    )
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({
        "total_orders": total_orders,
        "delivered_orders": delivered_orders,
        "total_spent": total_spent,
    })))
}

async fn order_detail(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    order_json(&st, id, claims.sub, claims.is_staff()).await
}

#[derive(Serialize, sqlx::FromRow)]
struct OrderRow {
    id: Uuid,
    #[serde(skip)]
    customer_id: Uuid,
    merchant_id: Uuid,
    merchant_name: String,
    status: String,
    subtotal: Decimal,
    delivery_fee: Decimal,
    total: Decimal,
    discount_amount: Decimal,
    payment_method: String,
    delivery_lat: f64,
    delivery_lng: f64,
    trip_id: Option<Uuid>,
    created_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Serialize, sqlx::FromRow)]
struct OrderItemRow {
    name: String,
    unit_price: Decimal,
    qty: i32,
}

async fn order_json(st: &AppState, id: Uuid, uid: Uuid, is_staff: bool) -> AppResult<Json<Value>> {
    let order: OrderRow = sqlx::query_as(
        "SELECT o.id, o.customer_id, o.merchant_id, m.name AS merchant_name, o.status, o.subtotal, \
                o.delivery_fee, o.total, o.discount_amount, o.payment_method, o.delivery_lat, o.delivery_lng, \
                o.trip_id, o.created_at \
         FROM orders o JOIN merchants m ON m.id = o.merchant_id WHERE o.id = $1",
    )
    .bind(id)
    .fetch_optional(&st.db)
    .await?
    .ok_or(AppError::NotFound)?;
    if order.customer_id != uid
        && !is_staff
        && !owns_or_staff(st, uid, is_staff, order.merchant_id).await?
    {
        return Err(AppError::Forbidden);
    }
    let items: Vec<OrderItemRow> =
        sqlx::query_as("SELECT name, unit_price, qty FROM order_items WHERE order_id = $1")
            .bind(id)
            .fetch_all(&st.db)
            .await?;
    let rated = if let Some(trip_id) = order.trip_id {
        sqlx::query_scalar::<_, Option<Uuid>>(
            "SELECT trip_id FROM ratings WHERE trip_id = $1 AND rater_id = $2",
        )
        .bind(trip_id)
        .bind(uid)
        .fetch_optional(&st.db)
        .await?
        .flatten()
        .is_some()
    } else {
        false
    };
    let merchant_rated = sqlx::query_scalar::<_, Option<Uuid>>(
        "SELECT order_id FROM merchant_ratings WHERE order_id = $1 AND rater_id = $2",
    )
    .bind(id)
    .bind(uid)
    .fetch_optional(&st.db)
    .await?
    .flatten()
    .is_some();
    let mut order_v = serde_json::to_value(order).unwrap_or_default();
    order_v["rated"] = json!(rated);
    order_v["merchant_rated"] = json!(merchant_rated);
    Ok(Json(json!({ "order": order_v, "items": items })))
}

#[derive(Deserialize)]
struct RateMerchantRequest {
    stars: i32,
    #[serde(default)]
    tags: Vec<String>,
}

async fn rate_merchant(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
    Json(b): Json<RateMerchantRequest>,
) -> AppResult<Json<Value>> {
    if !(1..=5).contains(&b.stars) {
        return Err(AppError::BadRequest("stars must be 1–5".into()));
    }
    let row: Option<(Uuid, Uuid, String)> =
        sqlx::query_as("SELECT customer_id, merchant_id, status FROM orders WHERE id = $1")
            .bind(id)
            .fetch_optional(&st.db)
            .await?;
    let (customer_id, merchant_id, status) = row.ok_or(AppError::NotFound)?;
    if customer_id != claims.sub {
        return Err(AppError::Forbidden);
    }
    if status != "delivered" {
        return Err(AppError::BadRequest(
            "can only rate a delivered order".into(),
        ));
    }
    sqlx::query(
        "INSERT INTO merchant_ratings (order_id, merchant_id, rater_id, stars, tags) \
         VALUES ($1, $2, $3, $4, $5) \
         ON CONFLICT (order_id, rater_id) DO UPDATE SET stars = EXCLUDED.stars, tags = EXCLUDED.tags",
    )
    .bind(id)
    .bind(merchant_id)
    .bind(claims.sub)
    .bind(b.stars)
    .bind(&b.tags)
    .execute(&st.db)
    .await?;
    Ok(Json(json!({ "ok": true, "merchant_id": merchant_id })))
}

#[derive(Deserialize)]
struct StatusReq {
    status: String,
}

async fn update_order_status(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
    Json(body): Json<StatusReq>,
) -> AppResult<Json<Value>> {
    const ALLOWED: [&str; 8] = [
        "confirmed",
        "preparing",
        "ready",
        "picked_up",
        "delivered",
        "cancelled",
        "rejected",
        "placed",
    ];
    if !ALLOWED.contains(&body.status.as_str()) {
        return Err(AppError::BadRequest("invalid order status".into()));
    }

    let row: Option<(Uuid, Uuid, String, Option<Uuid>, String, Decimal)> = sqlx::query_as(
        "SELECT customer_id, merchant_id, status, trip_id, payment_method, total FROM orders WHERE id = $1",
    )
    .bind(id)
    .fetch_optional(&st.db)
    .await?;
    let (customer_id, merchant_id, current, _trip_id, payment_method, total) =
        row.ok_or(AppError::NotFound)?;

    // The merchant owner (or staff) drives the order; a customer may only cancel
    // their own order before it's being prepared.
    let is_merchant = owns_or_staff(&st, claims.sub, claims.is_staff(), merchant_id).await?;
    if !is_merchant {
        let cancelling = body.status == "cancelled";
        let cancellable = matches!(current.as_str(), "placed" | "confirmed");
        if !(customer_id == claims.sub && cancelling && cancellable) {
            return Err(AppError::Forbidden);
        }
    }

    let already_terminal = matches!(current.as_str(), "cancelled" | "rejected" | "delivered");
    let refunding =
        !already_terminal && payment_method == "wallet" && matches!(body.status.as_str(), "cancelled" | "rejected");

    let mut tx = st.db.begin().await?;
    sqlx::query("UPDATE orders SET status = $2, updated_at = now() WHERE id = $1")
        .bind(id)
        .bind(&body.status)
        .execute(&mut *tx)
        .await?;
    if refunding {
        saarathi_core::wallet::credit_rider(&mut tx, customer_id, total, "order_refund", None, Some(id))
            .await?;
    }
    tx.commit().await?;

    notify_status_change(&st, id, merchant_id, customer_id, is_merchant, &body.status, refunding).await;

    // On 'ready', spawn the courier delivery trip via rides' internal API.
    // A confirmed zero nearby couriers doesn't block this — dispatch's own
    // progressive-widening search still runs and a courier may come online
    // during it — it's surfaced to the merchant as a heads-up, not a hard
    // stop, since the order is already made and prep already happened.
    let mut resp = order_json(&st, id, claims.sub, claims.is_staff()).await?;
    if body.status == "ready" {
        // A rejected/failed trip creation (delivery paused via the
        // `delivery.enabled` flag, or a transient rides-service hiccup)
        // must not turn into a hard error here — the order status change
        // above already committed, so surface it as a heads-up on the
        // response instead, same as the "no couriers nearby" case below.
        match spawn_courier(&st, id).await {
            Ok(Some(0)) => {
                if let Value::Object(map) = &mut resp.0 {
                    map.insert("no_couriers_nearby".into(), Value::Bool(true));
                }
            }
            Ok(_) => {}
            Err(e) => {
                tracing::warn!(order_id = %id, error = %e, "spawn_courier failed on order-ready");
                if let Value::Object(map) = &mut resp.0 {
                    map.insert("courier_dispatch_failed".into(), Value::Bool(true));
                }
            }
        }
    }

    Ok(resp)
}

/// Tell whichever side of the order didn't just act: the merchant driving the
/// order notifies the customer, a customer cancelling notifies the merchant.
async fn notify_status_change(
    st: &AppState,
    order_id: Uuid,
    merchant_id: Uuid,
    customer_id: Uuid,
    changed_by_merchant: bool,
    status: &str,
    refunding: bool,
) {
    let link = Some(format!("saarathi://order/{order_id}"));
    if !changed_by_merchant {
        // Only reachable for a customer-initiated cancel (see the guard above).
        // An unowned store (no merchant account) has nobody to notify.
        let Ok(Some(owner_id)) =
            sqlx::query_scalar::<_, Option<Uuid>>("SELECT owner_user_id FROM merchants WHERE id = $1")
                .bind(merchant_id)
                .fetch_one(&st.db)
                .await
        else {
            return;
        };
        crate::notify::send(
            &st.nats,
            owner_id,
            saarathi_core::domain::notif::TRANSACTIONAL,
            "Order cancelled",
            "The customer cancelled this order.",
            link,
        )
        .await;
        return;
    }

    let (title, body): (&str, String) = match status {
        "confirmed" => ("Order approved", "Your order has been approved and will be prepared shortly.".into()),
        "preparing" => ("Order is preparing", "Your order is being prepared.".into()),
        "picked_up" => ("Order picked up", "Your order has been picked up and is on its way.".into()),
        "delivered" => ("Order delivered", "Your order has been delivered. Enjoy!".into()),
        "cancelled" | "rejected" => {
            let verb = if status == "cancelled" { "cancelled" } else { "rejected" };
            let refund_note = if refunding { " Your payment has been refunded to your wallet." } else { "" };
            ("Order cancelled", format!("The merchant {verb} your order.{refund_note}"))
        }
        // "ready" and "placed" don't get a customer-facing message here — "ready"
        // is covered once a courier accepts the delivery trip (rides' own
        // "Driver on the way" notification), and "placed" is the initial state.
        _ => return,
    };
    crate::notify::send(
        &st.nats,
        customer_id,
        saarathi_core::domain::notif::TRANSACTIONAL,
        title,
        &body,
        link,
    )
    .await;
}

#[derive(Serialize)]
struct CreateDeliveryTripRequest {
    rider_id: Uuid,
    origin: LatLng,
    dest: LatLng,
    gross_fare: Decimal,
    payment_method: String,
}

#[derive(Deserialize)]
struct CreateDeliveryTripResponse {
    trip_id: Uuid,
}

/// Ask rides to create (and dispatch) the delivery trip for a ready order —
/// the API boundary this whole extraction exists to enforce: this service
/// never inserts into `trips` or calls dispatch itself.
///
/// Holds a `FOR UPDATE` row lock on the order across the outbound HTTP call so
/// two concurrent callers (a double-tap, a client retry racing the original
/// request) can't both pass the "not yet dispatched" check and spawn two
/// courier trips for the same order. This serializes dispatch per-order,
/// which is fine — it happens once, not on a hot path. A failed attempt
/// rolls the transaction back without writing `trip_id`, so a genuine retry
/// (merchant re-marks the order `ready`) still goes through cleanly.
/// Best-effort: `None` if the check itself failed (internal endpoint down,
/// network hiccup) rather than a genuine zero-count — callers should treat
/// that as "unknown, don't warn" rather than "confirmed no couriers", same
/// "a probe failing isn't the answer" convention as everywhere else this
/// pattern shows up (e.g. `presence::is_online` degrading to "treat as
/// offline" on a Redis outage, not "confirmed offline").
async fn nearby_courier_count(st: &AppState, lat: f64, lng: f64) -> Option<usize> {
    let resp = st
        .http
        .get(format!(
            "{}/v1/internal/nearby-drivers",
            st.config.rides_service_url
        ))
        .header("x-internal-secret", &st.config.internal_service_secret)
        .query(&[("lat", lat), ("lng", lng)])
        .query(&[("job_type", "delivery")])
        .send()
        .await
        .ok()?
        .error_for_status()
        .ok()?
        .json::<serde_json::Value>()
        .await
        .ok()?;
    resp.get("count")?.as_u64().map(|n| n as usize)
}

/// Returns the nearby-courier count at the merchant's own location right as
/// dispatch was attempted — `None` if the availability check itself failed
/// (see `nearby_courier_count`) rather than a confirmed zero, so the caller
/// can tell "no couriers" apart from "couldn't tell".
pub(crate) async fn spawn_courier(st: &AppState, order_id: Uuid) -> AppResult<Option<usize>> {
    let mut tx = st.db.begin().await?;
    let o: (Uuid, Uuid, Decimal, String, f64, f64, Option<Uuid>) = sqlx::query_as(
        "SELECT o.customer_id, o.merchant_id, o.delivery_fee, o.payment_method, \
                o.delivery_lat, o.delivery_lng, o.trip_id \
         FROM orders o WHERE o.id = $1 FOR UPDATE",
    )
    .bind(order_id)
    .fetch_one(&mut *tx)
    .await?;
    if o.6.is_some() {
        return Ok(None); // already dispatched
    }
    let (merchant_lat, merchant_lng): (f64, f64) =
        sqlx::query_as("SELECT lat, lng FROM merchants WHERE id = $1")
            .bind(o.1)
            .fetch_one(&mut *tx)
            .await?;

    let nearby = nearby_courier_count(st, merchant_lat, merchant_lng).await;

    let req = CreateDeliveryTripRequest {
        rider_id: o.0,
        origin: LatLng {
            lat: merchant_lat,
            lng: merchant_lng,
        },
        dest: LatLng { lat: o.4, lng: o.5 },
        gross_fare: o.2,
        payment_method: o.3,
    };
    let resp = st
        .http
        .post(format!(
            "{}/v1/internal/delivery-trips",
            st.config.rides_service_url
        ))
        .header("x-internal-secret", &st.config.internal_service_secret)
        .json(&req)
        .send()
        .await
        .map_err(anyhow::Error::from)
        .map_err(AppError::Other)?
        .error_for_status()
        .map_err(anyhow::Error::from)
        .map_err(AppError::Other)?
        .json::<CreateDeliveryTripResponse>()
        .await
        .map_err(anyhow::Error::from)
        .map_err(AppError::Other)?;

    sqlx::query("UPDATE orders SET trip_id = $2 WHERE id = $1")
        .bind(order_id)
        .bind(resp.trip_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(nearby)
}

// ── Merchant-facing ──────────────────────────────────────────────────────────

async fn my_merchants(
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
async fn merchant_menu(
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
async fn merchant_analytics(
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
struct MerchantOffer {
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

async fn list_offers(
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
async fn active_offers(
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
struct NearbyOffersQuery {
    vertical: Option<String>,
    lat: Option<f64>,
    lng: Option<f64>,
}

#[derive(Serialize, sqlx::FromRow)]
struct NearbyOffer {
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
async fn nearby_offers(
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
struct NewOffer {
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

async fn create_offer(
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

async fn deactivate_offer(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path((id, offer_id)): Path<(Uuid, Uuid)>,
) -> AppResult<Json<Value>> {
    if !owns_or_staff(&st, claims.sub, claims.is_staff(), id).await? {
        return Err(AppError::Forbidden);
    }
    let res = sqlx::query(
        "UPDATE merchant_offers SET active = false WHERE id = $1 AND merchant_id = $2",
    )
    .bind(offer_id)
    .bind(id)
    .execute(&st.db)
    .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(Json(json!({ "ok": true })))
}

#[derive(sqlx::FromRow)]
struct OfferCandidate {
    id: Uuid,
    kind: String,
    value: Option<Decimal>,
    max_discount: Option<Decimal>,
    daily_start_minute: Option<i32>,
    daily_end_minute: Option<i32>,
}

/// Picks whichever active, eligible offer saves the customer the most —
/// a `free_delivery` offer's "savings" is the delivery fee it waives,
/// percent/flat is the computed (capped) discount. At most one offer
/// applies per order, no stacking.
async fn best_matching_offer(
    st: &AppState,
    merchant_id: Uuid,
    subtotal: Decimal,
    delivery_fee: Decimal,
) -> Option<(Uuid, String, Decimal)> {
    let rows: Vec<OfferCandidate> = sqlx::query_as(
        "SELECT id, kind, value, max_discount, daily_start_minute, daily_end_minute \
         FROM merchant_offers \
         WHERE merchant_id = $1 AND active = true AND min_order_amount <= $2 \
           AND (starts_at IS NULL OR starts_at <= now()) \
           AND (ends_at IS NULL OR ends_at >= now())",
    )
    .bind(merchant_id)
    .bind(subtotal)
    .fetch_all(&st.db)
    .await
    .ok()?;
    if rows.is_empty() {
        return None;
    }

    // Nepal Time (UTC+5:45), matching rides' rules.rs — a self-contained,
    // one-off check here rather than pulling in the rides rule engine for
    // what's just a single daily window, not a general rule set.
    let now_minute = {
        use chrono::{TimeZone, Timelike};
        let tz = chrono::FixedOffset::east_opt(5 * 3600 + 45 * 60).expect("valid offset");
        let now = tz.from_utc_datetime(&chrono::Utc::now().naive_utc());
        (now.hour() * 60 + now.minute()) as i32
    };

    let mut best: Option<(Uuid, String, Decimal)> = None;
    for row in rows {
        if !in_daily_window(now_minute, row.daily_start_minute, row.daily_end_minute) {
            continue;
        }
        let savings = savings_for_offer(&row.kind, row.value, row.max_discount, subtotal, delivery_fee);
        if savings <= Decimal::ZERO {
            continue;
        }
        if best.as_ref().is_none_or(|(_, _, best_amt)| savings > *best_amt) {
            best = Some((row.id, row.kind, savings));
        }
    }
    best
}

/// Whether `now_minute` (minutes since midnight, local) falls in
/// `[start, end)` — wrapping past midnight when `start > end` (e.g. a
/// 22:00–02:00 happy hour). `None` bounds mean "always in window" (an
/// offer with no daily schedule).
fn in_daily_window(now_minute: i32, start: Option<i32>, end: Option<i32>) -> bool {
    let (Some(start), Some(end)) = (start, end) else {
        return true;
    };
    if start <= end {
        now_minute >= start && now_minute < end
    } else {
        now_minute >= start || now_minute < end
    }
}

/// What a single offer would save on this order — `free_delivery` waives the
/// fee entirely, `percent` is a capped percentage of the subtotal, anything
/// else (`flat`) is a fixed amount. Never negative.
fn savings_for_offer(
    kind: &str,
    value: Option<Decimal>,
    max_discount: Option<Decimal>,
    subtotal: Decimal,
    delivery_fee: Decimal,
) -> Decimal {
    match kind {
        "free_delivery" => delivery_fee,
        "percent" => {
            let mut d = (subtotal * value.unwrap_or_default() / Decimal::from(100)).round_dp(2);
            if let Some(cap) = max_discount
                && d > cap {
                    d = cap;
                }
            d
        }
        _ => value.unwrap_or_default(),
    }
}

/// Final charge for an order: subtotal minus whatever discount applied, plus
/// delivery — clamped so a discount that (somehow) exceeds subtotal+delivery
/// can never make the order free-and-then-some.
fn order_total(subtotal: Decimal, discount_amount: Decimal, delivery_fee: Decimal) -> Decimal {
    (subtotal - discount_amount + delivery_fee).max(Decimal::ZERO)
}

#[cfg(test)]
mod checkout_math_tests {
    use super::*;
    use rust_decimal_macros::dec;

    #[test]
    fn in_daily_window_no_schedule_is_always_open() {
        assert!(in_daily_window(0, None, None));
        assert!(in_daily_window(1439, None, None));
    }

    #[test]
    fn in_daily_window_same_day_range() {
        // 09:00-17:00
        assert!(!in_daily_window(8 * 60 + 59, Some(540), Some(1020)));
        assert!(in_daily_window(9 * 60, Some(540), Some(1020)));
        assert!(in_daily_window(16 * 60 + 59, Some(540), Some(1020)));
        assert!(!in_daily_window(17 * 60, Some(540), Some(1020))); // end is exclusive
    }

    #[test]
    fn in_daily_window_wraps_past_midnight() {
        // 22:00-02:00 happy hour
        let start = 22 * 60;
        let end = 2 * 60;
        assert!(in_daily_window(23 * 60, Some(start), Some(end)));
        assert!(in_daily_window(60, Some(start), Some(end))); // 01:00
        assert!(!in_daily_window(12 * 60, Some(start), Some(end))); // noon, outside
        assert!(!in_daily_window(end, Some(start), Some(end))); // 02:00 exact, exclusive
    }

    #[test]
    fn savings_free_delivery_waives_exactly_the_fee() {
        let s = savings_for_offer("free_delivery", None, None, dec!(500), dec!(60));
        assert_eq!(s, dec!(60));
    }

    #[test]
    fn savings_percent_is_capped_by_max_discount() {
        // 20% of 1000 = 200, but capped at 100.
        let s = savings_for_offer("percent", Some(dec!(20)), Some(dec!(100)), dec!(1000), dec!(0));
        assert_eq!(s, dec!(100));
    }

    #[test]
    fn savings_percent_uncapped_rounds_to_2dp() {
        let s = savings_for_offer("percent", Some(dec!(15)), None, dec!(333.33), dec!(0));
        assert_eq!(s, dec!(50.00)); // 333.33 * 0.15 = 49.9995 -> 50.00
    }

    #[test]
    fn savings_flat_kind_returns_the_raw_value() {
        let s = savings_for_offer("flat", Some(dec!(75)), None, dec!(1000), dec!(60));
        assert_eq!(s, dec!(75));
    }

    #[test]
    fn savings_missing_value_defaults_to_zero_not_a_panic() {
        assert_eq!(savings_for_offer("percent", None, None, dec!(1000), dec!(0)), dec!(0));
        assert_eq!(savings_for_offer("flat", None, None, dec!(1000), dec!(0)), dec!(0));
    }

    #[test]
    fn order_total_is_subtotal_minus_discount_plus_delivery() {
        assert_eq!(order_total(dec!(500), dec!(50), dec!(60)), dec!(510));
    }

    #[test]
    fn order_total_never_goes_negative() {
        // A discount that (in principle) exceeds subtotal+delivery must clamp
        // to zero, not charge a negative amount / pay the customer.
        assert_eq!(order_total(dec!(100), dec!(9999), dec!(0)), dec!(0));
    }

    #[test]
    fn order_total_with_no_discount_is_subtotal_plus_delivery() {
        assert_eq!(order_total(dec!(200), dec!(0), dec!(30)), dec!(230));
    }
}

#[derive(Deserialize)]
struct SetAvailable {
    is_available: bool,
}

async fn set_item_availability(
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
struct MerchantOrderQuery {
    status: Option<String>,
    #[serde(default)]
    limit: Option<i64>,
    #[serde(default)]
    offset: Option<i64>,
}

async fn merchant_orders(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Query(q): Query<MerchantOrderQuery>,
) -> AppResult<Json<Value>> {
    let rows: Vec<OrderRow> = sqlx::query_as(
        "SELECT o.id, o.customer_id, o.merchant_id, m.name AS merchant_name, o.status, o.subtotal, \
                o.delivery_fee, o.total, o.discount_amount, o.payment_method, o.delivery_lat, o.delivery_lng, \
                o.trip_id, o.created_at \
         FROM orders o JOIN merchants m ON m.id = o.merchant_id \
         WHERE ($2 OR m.owner_user_id = $1) AND ($3::text IS NULL OR o.status = $3) \
         ORDER BY o.created_at DESC LIMIT $4 OFFSET $5",
    )
    .bind(claims.sub)
    .bind(claims.is_staff())
    .bind(q.status)
    .bind(q.limit.unwrap_or(20).clamp(1, 100))
    .bind(q.offset.unwrap_or(0).max(0))
    .fetch_all(&st.db)
    .await?;
    Ok(Json(json!(rows)))
}

#[derive(Deserialize)]
struct AddItem {
    merchant_id: Uuid,
    name: String,
    price: Decimal,
    category: Option<String>,
    description: Option<String>,
}

async fn add_menu_item(
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

async fn upload_item_photo(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
    multipart: Multipart,
) -> AppResult<Json<Value>> {
    let merchant_id: Uuid =
        sqlx::query_scalar("SELECT merchant_id FROM menu_items WHERE id = $1")
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

async fn item_photo(
    State(st): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<impl IntoResponse> {
    let key: Option<String> =
        sqlx::query_scalar("SELECT photo_storage_key FROM menu_items WHERE id = $1")
            .bind(id)
            .fetch_optional(&st.db)
            .await?
            .flatten();
    let key = key.ok_or(AppError::NotFound)?;
    let bytes = st.docs.get(&key).await.map_err(AppError::Other)?;
    let mut headers = HeaderMap::new();
    headers.insert(header::CONTENT_TYPE, "application/octet-stream".parse().unwrap());
    Ok((StatusCode::OK, headers, Bytes::from(bytes)))
}

async fn upload_merchant_photo(
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

async fn merchant_photo(
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
    headers.insert(header::CONTENT_TYPE, "application/octet-stream".parse().unwrap());
    Ok((StatusCode::OK, headers, Bytes::from(bytes)))
}

#[derive(Deserialize)]
struct SetOpen {
    merchant_id: Uuid,
    is_open: bool,
}

async fn set_open(
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
struct MerchantApply {
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
async fn apply_merchant(
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

#[derive(Deserialize)]
struct CreateMerchant {
    name: String,
    vertical: String,
    lat: f64,
    lng: f64,
    address: Option<String>,
    phone: Option<String>,
    /// Ties this store to a merchant-app account the vendor already has.
    /// Left unset for a plain walk-in vendor with no app account yet — the
    /// store stays unowned (`owner_user_id NULL`) rather than defaulting to
    /// the onboarding staff member's own account, which would (a) be wrong
    /// attribution and (b) collide with the one-store-per-owner rule the
    /// moment that staff member onboards a second walk-in.
    owner_user_id: Option<Uuid>,
    prep_mins: Option<i32>,
}

async fn create_merchant(
    State(st): State<AppState>,
    crate::auth::StaffUser(claims): crate::auth::StaffUser,
    Json(body): Json<CreateMerchant>,
) -> AppResult<Json<Value>> {
    if !matches!(body.vertical.as_str(), "food" | "grocery") {
        return Err(AppError::BadRequest(
            "vertical must be 'food' or 'grocery'".into(),
        ));
    }
    let owner = body.owner_user_id;
    // One store per registration, same rule as self-service apply — only
    // applies when an owner was actually specified; unowned walk-ins are
    // exempt since they don't hold anyone's one-store slot.
    if let Some(owner) = owner {
        let existing: Option<Uuid> = sqlx::query_scalar(
            "SELECT id FROM merchants WHERE owner_user_id = $1 AND status <> 'rejected'",
        )
        .bind(owner)
        .fetch_optional(&st.db)
        .await?;
        if existing.is_some() {
            return Err(AppError::Coded(
                StatusCode::CONFLICT,
                ErrorCode::Conflict,
                "this owner already has a registered store".into(),
            ));
        }
    }
    // Staff-onboarded (on-site) stores skip the review queue entirely — a
    // staff member creating this directly has already vetted it in person,
    // same reasoning as drivers' `onboarded_by` walk-in KYC path.
    let id: Uuid = sqlx::query_scalar(
        "INSERT INTO merchants \
             (owner_user_id, name, vertical, address, phone, lat, lng, prep_mins, \
              status, approved_at, reviewed_by, reviewed_at) \
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,'approved',now(),$9,now()) RETURNING id",
    )
    .bind(owner)
    .bind(body.name.trim())
    .bind(&body.vertical)
    .bind(body.address)
    .bind(body.phone)
    .bind(body.lat)
    .bind(body.lng)
    .bind(body.prep_mins.unwrap_or(20))
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({ "id": id, "owner_user_id": owner })))
}

// ── Staff review queue ──────────────────────────────────────────────────────

#[derive(Deserialize)]
struct MerchantQueueQuery {
    #[serde(default)]
    status: Option<String>,
}

/// Pending applications by default (`?status=all` for every store, any
/// state) — the review queue's landing view.
async fn merchant_queue(
    State(st): State<AppState>,
    crate::auth::StaffUser(_claims): crate::auth::StaffUser,
    Query(q): Query<MerchantQueueQuery>,
) -> AppResult<Json<Vec<Merchant>>> {
    let all = q.status.as_deref() == Some("all");
    let rows: Vec<Merchant> = sqlx::query_as(
        "SELECT id, name, vertical, address, phone, lat, lng, prep_mins, is_open, rating, image_key, \
                status::text, rejection_reason, \
                0::double precision AS distance_m \
         FROM merchants WHERE $1 OR status = 'pending' ORDER BY created_at",
    )
    .bind(all)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

async fn approve_merchant(
    State(st): State<AppState>,
    crate::auth::StaffUser(claims): crate::auth::StaffUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    if !claims.can_approve() {
        return Err(AppError::Forbidden);
    }
    // Guarded on the current status so two staff acting on the same
    // application at once can't clobber each other — the loser's WHERE
    // matches nothing (same pattern as driver KYC approval).
    let updated: Option<(Option<Uuid>, String, String, f64, f64)> = sqlx::query_as(
        "UPDATE merchants SET status = 'approved', approved_at = now(), reviewed_at = now(), \
         reviewed_by = $2, rejection_reason = NULL \
         WHERE id = $1 AND status = 'pending' \
         RETURNING owner_user_id, name, vertical, lat, lng",
    )
    .bind(id)
    .bind(claims.sub)
    .fetch_optional(&st.db)
    .await?;
    let Some((owner, name, vertical, lat, lng)) = updated else {
        return Err(AppError::Coded(
            StatusCode::CONFLICT,
            ErrorCode::Conflict,
            "store has already been reviewed".into(),
        ));
    };

    // Findable via address search immediately, same as an approved
    // place-contribution — best-effort, never blocks approval on a Pelias
    // hiccup (see saarathi_core::pelias_index's own doc comment).
    saarathi_core::pelias_index::index_place(&st.config.pelias_es_url, id, &vertical, &name, lat, lng)
        .await;

    if let Some(owner) = owner {
        crate::notify::send(
            &st.nats,
            owner,
            saarathi_core::domain::notif::TRANSACTIONAL,
            "Store approved",
            "Your store is approved — you can open it and start taking orders.",
            Some("saarathi://merchant/dashboard".to_string()),
        )
        .await;
    }
    Ok(Json(json!({ "ok": true })))
}

/// Appends to the shared `audit_log` table — this service has no `audit`
/// module of its own (only `auth` does); duplicating this one small insert
/// is cheaper than a new cross-service dependency for it.
async fn audit_record(
    db: &sqlx::PgPool,
    actor: Uuid,
    action: &str,
    entity_id: Uuid,
    detail: Value,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO audit_log (actor_user_id, action, entity_type, entity_id, detail) \
         VALUES ($1, $2, 'merchant', $3, $4)",
    )
    .bind(actor)
    .bind(action)
    .bind(entity_id)
    .bind(detail)
    .execute(db)
    .await?;
    Ok(())
}

#[derive(Deserialize)]
struct UpdateMerchant {
    name: Option<String>,
    address: Option<String>,
    phone: Option<String>,
    prep_mins: Option<i32>,
    vertical: Option<String>,
}

/// Staff correction of a listing's own details — typo fixes, not the
/// approve/reject decision or the owner's own open/closed toggle.
async fn update_merchant(
    State(st): State<AppState>,
    crate::auth::StaffUser(claims): crate::auth::StaffUser,
    Path(id): Path<Uuid>,
    Json(body): Json<UpdateMerchant>,
) -> AppResult<Json<Value>> {
    if !claims.can_approve() {
        return Err(AppError::Forbidden);
    }
    if let Some(name) = &body.name
        && name.trim().is_empty() {
            return Err(AppError::BadRequest("name cannot be empty".into()));
        }
    if let Some(address) = &body.address
        && address.trim().is_empty() {
            return Err(AppError::BadRequest("address cannot be empty".into()));
        }
    if let Some(vertical) = &body.vertical
        && !matches!(vertical.as_str(), "food" | "grocery") {
            return Err(AppError::BadRequest(
                "vertical must be 'food' or 'grocery'".into(),
            ));
        }

    let name = body.name.as_deref().map(str::trim);
    let updated: Option<(Uuid,)> = sqlx::query_as(
        "UPDATE merchants SET \
             name = COALESCE($2, name), \
             address = COALESCE($3, address), \
             phone = COALESCE($4, phone), \
             prep_mins = COALESCE($5, prep_mins), \
             vertical = COALESCE($6, vertical) \
         WHERE id = $1 RETURNING id",
    )
    .bind(id)
    .bind(name)
    .bind(&body.address)
    .bind(&body.phone)
    .bind(body.prep_mins)
    .bind(&body.vertical)
    .fetch_optional(&st.db)
    .await?;
    updated.ok_or(AppError::NotFound)?;

    audit_record(
        &st.db,
        claims.sub,
        "merchant.update",
        id,
        json!({
            "name": name,
            "address": body.address,
            "phone": body.phone,
            "prep_mins": body.prep_mins,
            "vertical": body.vertical,
        }),
    )
    .await?;

    Ok(Json(json!({ "ok": true })))
}

#[derive(Deserialize)]
struct RejectMerchant {
    reason: String,
}

async fn reject_merchant(
    State(st): State<AppState>,
    crate::auth::StaffUser(claims): crate::auth::StaffUser,
    Path(id): Path<Uuid>,
    Json(body): Json<RejectMerchant>,
) -> AppResult<Json<Value>> {
    if !claims.can_approve() {
        return Err(AppError::Forbidden);
    }
    if body.reason.trim().is_empty() {
        return Err(AppError::BadRequest(
            "a rejection reason is required".into(),
        ));
    }
    let updated: Option<(Option<Uuid>,)> = sqlx::query_as(
        "UPDATE merchants SET status = 'rejected', reviewed_at = now(), reviewed_by = $2, \
         rejection_reason = $3, approved_at = NULL \
         WHERE id = $1 AND status = 'pending' RETURNING owner_user_id",
    )
    .bind(id)
    .bind(claims.sub)
    .bind(&body.reason)
    .fetch_optional(&st.db)
    .await?;
    let Some((owner,)) = updated else {
        return Err(AppError::Coded(
            StatusCode::CONFLICT,
            ErrorCode::Conflict,
            "store has already been reviewed".into(),
        ));
    };
    if let Some(owner) = owner {
        crate::notify::send(
            &st.nats,
            owner,
            saarathi_core::domain::notif::TRANSACTIONAL,
            "Store application rejected",
            &format!("Your store application was rejected: {}", body.reason),
            None,
        )
        .await;
    }
    Ok(Json(json!({ "ok": true })))
}
