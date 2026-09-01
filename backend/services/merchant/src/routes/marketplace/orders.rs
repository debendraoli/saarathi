//! Customer order placement/checkout, order status transitions, courier
//! dispatch on `ready`, ratings, and the merchant-facing order list.

use super::owns_or_staff;
use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::routes::zone;
use crate::state::AppState;
use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::Json;
use rust_decimal::Decimal;
use saarathi_core::idempotency::{self, Reservation};
use saarathi_core::routing::{LatLng, RouteProfile};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

// ── Orders ───────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct OrderLine {
    menu_item_id: Uuid,
    qty: i32,
}

#[derive(Deserialize)]
pub(super) struct PlaceOrder {
    merchant_id: Uuid,
    items: Vec<OrderLine>,
    delivery: LatLng,
    delivery_note: Option<String>,
    #[serde(default)]
    payment_method: Option<String>,
}

pub(super) async fn place_order(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    headers: HeaderMap,
    Json(body): Json<PlaceOrder>,
) -> AppResult<Json<Value>> {
    // A dropped response (flaky network) shouldn't turn one tap of "place
    // order" into two orders — same idempotency-key protocol as rides/payments.
    let idem_key = saarathi_core::idempotency::key_from_headers(&headers)
        .ok_or_else(|| AppError::BadRequest("X-Idempotency-Key header is required".into()))?;
    let mut reserve_tx = st.db.begin().await?;
    let reservation = idempotency::reserve(
        &mut reserve_tx,
        &idem_key,
        claims.sub,
        "marketplace.place_order",
    )
    .await
    .map_err(anyhow::Error::from)
    .map_err(AppError::Other)?;
    reserve_tx.commit().await?;
    if let Reservation::Replay { body, .. } = reservation {
        let order_id: Uuid =
            serde_json::from_value(body["id"].clone()).map_err(|e| AppError::Other(e.into()))?;
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

    // Independent reads — neither depends on the other's result.
    let (merchant, in_zone) = tokio::join!(
        sqlx::query_as::<_, (f64, f64, bool)>(
            "SELECT lat, lng, is_open FROM merchants WHERE id = $1"
        )
        .bind(body.merchant_id)
        .fetch_optional(&st.db),
        zone::is_point_in_zone(&st, body.merchant_id, body.delivery.lat, body.delivery.lng),
    );
    let merchant = merchant?.ok_or(AppError::NotFound)?;
    let in_zone = in_zone.map_err(AppError::Other)?;
    if !merchant.2 {
        return Err(AppError::BadRequest("merchant is closed".into()));
    }
    if in_zone == Some(false) {
        return Err(AppError::BadRequest(
            "delivery address is outside this merchant's delivery zone".into(),
        ));
    }

    // Price from the DB — never trust client-supplied prices. Batched as a
    // single `ANY($1)` lookup instead of one round trip per line, so a
    // multi-item cart doesn't pay N sequential queries.
    for line in &body.items {
        if line.qty <= 0 {
            return Err(AppError::BadRequest("item qty must be positive".into()));
        }
    }
    let item_ids: Vec<Uuid> = body.items.iter().map(|l| l.menu_item_id).collect();
    let rows: Vec<(Uuid, String, Decimal)> = sqlx::query_as(
        "SELECT id, name, price FROM menu_items \
         WHERE id = ANY($1) AND merchant_id = $2 AND is_available",
    )
    .bind(&item_ids)
    .bind(body.merchant_id)
    .fetch_all(&st.db)
    .await?;
    let by_id: std::collections::HashMap<Uuid, (String, Decimal)> = rows
        .into_iter()
        .map(|(id, name, price)| (id, (name, price)))
        .collect();

    let mut subtotal = Decimal::ZERO;
    let mut priced: Vec<(Uuid, String, Decimal, i32)> = Vec::new();
    for line in &body.items {
        let (name, price) = by_id.get(&line.menu_item_id).cloned().ok_or_else(|| {
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
        saarathi_core::wallet::debit_rider(
            &mut tx,
            claims.sub,
            total,
            "order_charge",
            Some(order_id),
        )
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

    let owner_id: Option<Uuid> =
        sqlx::query_scalar("SELECT owner_user_id FROM merchants WHERE id = $1")
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
pub(super) struct PageQuery {
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

pub(super) async fn my_orders(
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
pub(super) async fn my_order_stats(
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

pub(super) async fn order_detail(
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
pub(super) struct RateMerchantRequest {
    stars: i32,
    #[serde(default)]
    tags: Vec<String>,
}

pub(super) async fn rate_merchant(
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
pub(super) struct StatusReq {
    status: String,
}

pub(super) async fn update_order_status(
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
    let refunding = !already_terminal
        && payment_method == "wallet"
        && matches!(body.status.as_str(), "cancelled" | "rejected");

    let mut tx = st.db.begin().await?;
    sqlx::query("UPDATE orders SET status = $2, updated_at = now() WHERE id = $1")
        .bind(id)
        .bind(&body.status)
        .execute(&mut *tx)
        .await?;
    if refunding {
        saarathi_core::wallet::credit_rider(
            &mut tx,
            customer_id,
            total,
            "order_refund",
            None,
            Some(id),
        )
        .await?;
    }
    tx.commit().await?;

    // Fire-and-forget: purely a push notification, no return value the
    // response depends on, and it runs strictly after the order-status +
    // refund transaction above already committed — safe to background so
    // it doesn't add to this request's latency.
    {
        let st = st.clone();
        let status = body.status.clone();
        tokio::spawn(async move {
            notify_status_change(
                &st,
                id,
                merchant_id,
                customer_id,
                is_merchant,
                &status,
                refunding,
            )
            .await;
        });
    }

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
        let Ok(Some(owner_id)) = sqlx::query_scalar::<_, Option<Uuid>>(
            "SELECT owner_user_id FROM merchants WHERE id = $1",
        )
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
        "confirmed" => (
            "Order approved",
            "Your order has been approved and will be prepared shortly.".into(),
        ),
        "preparing" => ("Order is preparing", "Your order is being prepared.".into()),
        "picked_up" => (
            "Order picked up",
            "Your order has been picked up and is on its way.".into(),
        ),
        "delivered" => (
            "Order delivered",
            "Your order has been delivered. Enjoy!".into(),
        ),
        "cancelled" | "rejected" => {
            let verb = if status == "cancelled" {
                "cancelled"
            } else {
                "rejected"
            };
            let refund_note = if refunding {
                " Your payment has been refunded to your wallet."
            } else {
                ""
            };
            (
                "Order cancelled",
                format!("The merchant {verb} your order.{refund_note}"),
            )
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
        .header(
            saarathi_core::api::headers::X_INTERNAL_SECRET,
            &st.config.internal_service_secret,
        )
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
        .header(
            saarathi_core::api::headers::X_INTERNAL_SECRET,
            &st.config.internal_service_secret,
        )
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
        let savings = savings_for_offer(
            &row.kind,
            row.value,
            row.max_discount,
            subtotal,
            delivery_fee,
        );
        if savings <= Decimal::ZERO {
            continue;
        }
        if best
            .as_ref()
            .is_none_or(|(_, _, best_amt)| savings > *best_amt)
        {
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
                && d > cap
            {
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
        let s = savings_for_offer(
            "percent",
            Some(dec!(20)),
            Some(dec!(100)),
            dec!(1000),
            dec!(0),
        );
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
        assert_eq!(
            savings_for_offer("percent", None, None, dec!(1000), dec!(0)),
            dec!(0)
        );
        assert_eq!(
            savings_for_offer("flat", None, None, dec!(1000), dec!(0)),
            dec!(0)
        );
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
pub(super) struct MerchantOrderQuery {
    status: Option<String>,
    #[serde(default)]
    limit: Option<i64>,
    #[serde(default)]
    offset: Option<i64>,
}

pub(super) async fn merchant_orders(
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
