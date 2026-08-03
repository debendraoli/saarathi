//! Marketplace (food / grocery): merchants, menus, and customer orders. An
//! order's courier leg reuses delivery — when it's marked `ready` we spawn a
//! `trip_type='delivery'` trip so the existing dispatch + settlement plumbing
//! carries it to the customer.

use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::models::{Trip, TRIP_COLS};
use crate::routing::{LatLng, RouteProfile};
use crate::state::AppState;
use axum::extract::{Path, Query, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use rust_decimal::Decimal;
use saarathi_core::money::Money;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/merchants", get(list_merchants))
        .route("/v1/merchants/{id}", get(merchant_detail))
        .route("/v1/orders", get(my_orders).post(place_order))
        .route("/v1/orders/{id}", get(order_detail))
        .route("/v1/orders/{id}/status", post(update_order_status))
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
                ST_Distance(geog, ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography) AS distance_m \
         FROM merchants \
         WHERE is_open AND ($3::text IS NULL OR vertical = $3) \
         ORDER BY distance_m ASC LIMIT 50",
    )
    .bind(lat)
    .bind(lng)
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
    Json(body): Json<PlaceOrder>,
) -> AppResult<Json<Value>> {
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
    let delivery_fee =
        (st.config.delivery_base_fare + route.distance_km * st.config.delivery_per_km).round_dp(2);
    let total = subtotal + delivery_fee;

    let mut tx = st.db.begin().await?;
    let order_id: Uuid = sqlx::query_scalar(
        "INSERT INTO orders (customer_id, merchant_id, subtotal, delivery_fee, total, \
            payment_method, delivery_lat, delivery_lng, delivery_note) \
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING id",
    )
    .bind(claims.sub)
    .bind(body.merchant_id)
    .bind(subtotal)
    .bind(delivery_fee)
    .bind(total)
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
    tx.commit().await?;

    order_json(&st, order_id, claims.sub, false).await
}

async fn my_orders(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Value>> {
    let rows: Vec<OrderRow> = sqlx::query_as(
        "SELECT o.id, o.customer_id, o.merchant_id, m.name AS merchant_name, o.status, o.subtotal, \
                o.delivery_fee, o.total, o.payment_method, o.delivery_lat, o.delivery_lng, \
                o.trip_id, o.created_at \
         FROM orders o JOIN merchants m ON m.id = o.merchant_id \
         WHERE o.customer_id = $1 ORDER BY o.created_at DESC LIMIT 50",
    )
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(json!(rows)))
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
                o.delivery_fee, o.total, o.payment_method, o.delivery_lat, o.delivery_lng, \
                o.trip_id, o.created_at \
         FROM orders o JOIN merchants m ON m.id = o.merchant_id WHERE o.id = $1",
    )
    .bind(id)
    .fetch_optional(&st.db)
    .await?
    .ok_or(AppError::NotFound)?;
    if order.customer_id != uid && !is_staff {
        return Err(AppError::Forbidden);
    }
    let items: Vec<OrderItemRow> =
        sqlx::query_as("SELECT name, unit_price, qty FROM order_items WHERE order_id = $1")
            .bind(id)
            .fetch_all(&st.db)
            .await?;
    Ok(Json(json!({ "order": order, "items": items })))
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

    let row: Option<(Uuid, String, Option<Uuid>)> =
        sqlx::query_as("SELECT customer_id, status, trip_id FROM orders WHERE id = $1")
            .bind(id)
            .fetch_optional(&st.db)
            .await?;
    let (customer_id, current, _trip_id) = row.ok_or(AppError::NotFound)?;

    // A customer may only cancel their own order before it's being prepared.
    let is_customer = customer_id == claims.sub;
    if !claims.is_staff() {
        let cancelling = body.status == "cancelled";
        let cancellable = matches!(current.as_str(), "placed" | "confirmed");
        if !(is_customer && cancelling && cancellable) {
            return Err(AppError::Forbidden);
        }
    }

    sqlx::query("UPDATE orders SET status = $2, updated_at = now() WHERE id = $1")
        .bind(id)
        .bind(&body.status)
        .execute(&st.db)
        .await?;

    // On 'ready', spawn the courier delivery trip and dispatch it.
    if body.status == "ready" {
        spawn_courier(&st, id).await?;
    }

    order_json(&st, id, claims.sub, claims.is_staff()).await
}

/// Create the delivery trip for a ready order and kick dispatch.
async fn spawn_courier(st: &AppState, order_id: Uuid) -> AppResult<()> {
    let o: (Uuid, Uuid, Decimal, String, f64, f64, Option<Uuid>) = sqlx::query_as(
        "SELECT o.customer_id, o.merchant_id, o.delivery_fee, o.payment_method, \
                o.delivery_lat, o.delivery_lng, o.trip_id \
         FROM orders o WHERE o.id = $1",
    )
    .bind(order_id)
    .fetch_one(&st.db)
    .await?;
    if o.6.is_some() {
        return Ok(()); // already dispatched
    }
    let (merchant_lat, merchant_lng): (f64, f64) =
        sqlx::query_as("SELECT lat, lng FROM merchants WHERE id = $1")
            .bind(o.1)
            .fetch_one(&st.db)
            .await?;

    let route = st
        .router
        .route_path(
            &[
                LatLng {
                    lat: merchant_lat,
                    lng: merchant_lng,
                },
                LatLng {
                    lat: o.4,
                    lng: o.5,
                },
            ],
            RouteProfile::Motorcycle,
        )
        .await;

    let fee = o.2;
    let (commission, accident_fund, driver_payout) =
        saarathi_core::pricing::split_fare(Money::from_decimal(fee), st.config.commission_rate);

    let trip: Trip = sqlx::query_as(&format!(
        "INSERT INTO trips (rider_id, trip_type, vehicle_class, origin_lat, origin_lng, \
            dest_lat, dest_lng, distance_km, duration_secs, gross_fare, discount_amount, \
            final_fare, commission, accident_fund, driver_payout, payment_method) \
         VALUES ($1,'delivery','two_wheeler',$2,$3,$4,$5,$6,$7,$8,0,$8,$9,$10,$11,$12) \
         RETURNING {TRIP_COLS}"
    ))
    .bind(o.0)
    .bind(merchant_lat)
    .bind(merchant_lng)
    .bind(o.4)
    .bind(o.5)
    .bind(route.distance_km)
    .bind(route.duration_secs)
    .bind(fee)
    .bind(commission.amount())
    .bind(accident_fund.amount())
    .bind(driver_payout.amount())
    .bind(&o.3)
    .fetch_one(&st.db)
    .await?;

    sqlx::query("UPDATE orders SET trip_id = $2 WHERE id = $1")
        .bind(order_id)
        .bind(trip.id)
        .execute(&st.db)
        .await?;

    tokio::spawn({
        let st = st.clone();
        let trip_id = trip.id;
        async move {
            let _ = crate::dispatch::dispatch_trip(&st, trip_id).await;
        }
    });
    Ok(())
}
