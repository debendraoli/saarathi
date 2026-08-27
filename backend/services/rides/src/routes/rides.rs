//! Ride lifecycle + fare estimate endpoints.

use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::models::{Trip, TRIP_COLS};
use crate::pricing::{self, Estimate};
use crate::routing::{LatLng, RouteProfile, RouteStep};
use crate::state::AppState;
use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::{
    routing::{get, post},
    Json, Router,
};
use rust_decimal::Decimal;
use saarathi_core::api::ErrorCode;
use saarathi_core::idempotency::{self, Reservation};
use serde::Deserialize;
use serde::Serialize;
use serde_json::{json, Value};
use uuid::Uuid;

#[derive(sqlx::FromRow)]
struct TripMoney {
    rider_id: Uuid,
    driver_id: Option<Uuid>,
    trip_type: String,
    status: String,
    gross_fare: Decimal,
    commission: Decimal,
    accident_fund: Decimal,
    driver_payout: Decimal,
    final_fare: Decimal,
    payment_method: String,
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/rides/estimate", post(estimate))
        .route("/v1/rides/route", post(route_geometry))
        .route("/v1/rides", post(create).get(list_mine))
        .route("/v1/rides/mine/stats", get(my_stats))
        .route("/v1/rides/driver/today", get(driver_today))
        .route("/v1/rides/driver/earnings", get(driver_earnings))
        .route("/v1/rides/{id}", get(get_trip))
        .route("/v1/rides/{id}/participants", get(get_participants))
        .route("/v1/rides/{id}/status", post(update_status))
}

#[derive(Deserialize)]
struct RideRequest {
    origin: LatLng,
    dest: LatLng,
    vehicle_class: String,
    /// Optional intermediate waypoints (multi-stop rides).
    #[serde(default)]
    stops: Vec<LatLng>,
    #[serde(default)]
    code: Option<String>,
    /// 'cash' (default) or 'wallet' (pay from prepaid credits).
    #[serde(default)]
    payment_method: Option<String>,
    /// Bounded fare bargaining: a rider's proposed fare (clamped to the legal
    /// band). In `pricing_mode: "bid"` this instead seeds the auction's
    /// initial ask (also clamped) rather than an immediately-agreed price.
    #[serde(default)]
    offered_fare: Option<Decimal>,
    /// 'instant' (default: today's single algorithmic-fare dispatch) or
    /// 'bid' (open the trip to the fare auction — see `routes::bidding`).
    #[serde(default)]
    pricing_mode: Option<String>,
    /// Starting dispatch search radius (km), overriding the service default.
    /// Set on a "search wider" re-request after a no-driver cancellation.
    #[serde(default)]
    radius_km: Option<f64>,
    /// Request a specific driver by phone (someone this rider has ridden
    /// with before) — `dispatch_trip` tries them first, then falls back to
    /// normal matching. See `resolve_preferred_driver`.
    #[serde(default)]
    preferred_driver_phone: Option<String>,
}

/// Resolves a "request this driver" phone number to a driver id — only if
/// it belongs to an active driver *this rider has completed a trip with
/// before*. Deliberately not open to any phone number: without that check,
/// this endpoint would let anyone page a driver repeatedly just by knowing
/// their number, which is a real harassment vector. Silently returns `Ok(None)`
/// for anything else (unknown number, not a driver, no shared trip history)
/// rather than leaking *which* of those it was — the rider doesn't need to
/// know if a number belongs to a driver they've simply never ridden with, vs.
/// a driver at all, vs. a typo; the trip books normally either way, minus
/// the priority-offer step.
async fn resolve_preferred_driver(
    pool: &sqlx::PgPool,
    rider_id: Uuid,
    phone: &str,
) -> AppResult<Option<Uuid>> {
    let phone = phone.trim();
    if phone.is_empty() {
        return Ok(None);
    }
    let driver_id: Option<Uuid> = sqlx::query_scalar(
        "SELECT id FROM users WHERE phone = $1 AND role = 'driver'",
    )
    .bind(phone)
    .fetch_optional(pool)
    .await?;
    let Some(driver_id) = driver_id else {
        return Ok(None);
    };
    let rode_together: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM trips \
         WHERE rider_id = $1 AND driver_id = $2 AND status = 'completed')",
    )
    .bind(rider_id)
    .bind(driver_id)
    .fetch_one(pool)
    .await?;
    Ok(rode_together.then_some(driver_id))
}

async fn estimate(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<RideRequest>,
) -> AppResult<Json<Estimate>> {
    let (est, _route) = pricing::estimate(
        &st,
        claims.sub,
        body.origin,
        body.dest,
        &body.stops,
        &body.vehicle_class,
        body.code.as_deref(),
    )
    .await?;
    Ok(Json(est))
}

#[derive(Deserialize)]
struct RouteReq {
    origin: LatLng,
    dest: LatLng,
    #[serde(default)]
    stops: Vec<LatLng>,
    #[serde(default)]
    vehicle_class: Option<String>,
}

#[derive(Serialize)]
struct RouteResp {
    distance_km: Decimal,
    duration_secs: i32,
    /// Ordered road-shape points for drawing the route polyline on the map.
    geometry: Vec<LatLng>,
    /// Turn-by-turn maneuvers, in order — empty when the routing engine
    /// couldn't supply them (offline fallback).
    steps: Vec<RouteStep>,
}

/// Road-following route geometry for the map (pickup → stops → destination).
/// Falls back to a straight line when the routing engine is unreachable.
async fn route_geometry(
    State(st): State<AppState>,
    AuthUser(_claims): AuthUser,
    Json(body): Json<RouteReq>,
) -> AppResult<Json<RouteResp>> {
    let profile = match body.vehicle_class.as_deref() {
        Some(v) => RouteProfile::from_wire(v),
        None => RouteProfile::Motorcycle,
    };
    let mut path = Vec::with_capacity(body.stops.len() + 2);
    path.push(body.origin);
    path.extend_from_slice(&body.stops);
    path.push(body.dest);
    let route = st.router.route_path(&path, profile).await;
    Ok(Json(RouteResp {
        distance_km: route.distance_km,
        duration_secs: route.duration_secs,
        geometry: route.geometry,
        steps: route.steps,
    }))
}

const MAX_RIDER_CANCELS_PER_WINDOW: i64 = 3;
const RIDER_CANCEL_WINDOW_HOURS: i32 = 24;

async fn create(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    headers: HeaderMap,
    Json(body): Json<RideRequest>,
) -> AppResult<Json<Trip>> {
    // Circuit breaker: ops can freeze new ride intake from the dashboard.
    if !crate::flags::is_enabled(&st, crate::flags::RIDES_NEW_REQUESTS, true).await {
        return Err(AppError::disabled(
            "ride requests are temporarily paused; please try again shortly",
        ));
    }

    let idem_key = headers
        .get("x-idempotency-key")
        .and_then(|v| v.to_str().ok())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            AppError::bad(
                ErrorCode::Validation,
                "X-Idempotency-Key header is required",
            )
        })?
        .to_string();

    // Claim the key up front, before any of the booking work below, so a
    // double-tap/retry replays the first trip instead of creating a second.
    let mut reserve_tx = st.db.begin().await?;
    let reservation =
        idempotency::reserve(&mut reserve_tx, &idem_key, claims.sub, "rides.create").await?;
    reserve_tx.commit().await?;
    if let Reservation::Replay { status: _, body } = reservation {
        let trip: Trip = serde_json::from_value(body).map_err(anyhow::Error::from)?;
        return Ok(Json(trip));
    }

    // One active personal ride at a time — a rider can't stack requests.
    // Delivery/parcel trips (trip_type='delivery') are a separate concern and
    // aren't gated here.
    let active: Option<Uuid> = sqlx::query_scalar(
        "SELECT id FROM trips WHERE rider_id = $1 AND trip_type = 'ride' \
         AND status NOT IN ('completed', 'cancelled') LIMIT 1",
    )
    .bind(claims.sub)
    .fetch_optional(&st.db)
    .await?;
    if let Some(trip_id) = active {
        return Err(AppError::conflict(
            ErrorCode::Conflict,
            format!("you already have an active ride ({trip_id}) — finish or cancel it first"),
        ));
    }

    // Rider-side mirror of the driver cancellation-rate limit in
    // dispatch.rs::accept_offer — a cooldown on booking, not a ban, once a
    // rider has cancelled too many *matched* rides in a short window. Only
    // counts cancellations after a driver was already assigned
    // (driver_id IS NOT NULL): backing out while still searching costs
    // nobody real time, but cancelling on an en-route driver does, which is
    // the behaviour this actually needs to discourage.
    let recent_cancels: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM trips \
         WHERE rider_id = $1 AND status = 'cancelled' AND cancelled_by_role = 'rider' \
           AND driver_id IS NOT NULL \
           AND cancelled_at > now() - make_interval(hours => $2)",
    )
    .bind(claims.sub)
    .bind(RIDER_CANCEL_WINDOW_HOURS)
    .fetch_one(&st.db)
    .await?;
    if recent_cancels >= MAX_RIDER_CANCELS_PER_WINDOW {
        return Err(AppError::bad(
            ErrorCode::TooManyCancellations,
            format!(
                "too many cancelled rides in the last {RIDER_CANCEL_WINDOW_HOURS}h — try again later"
            ),
        ));
    }

    let (est, _route) = pricing::estimate(
        &st,
        claims.sub,
        body.origin,
        body.dest,
        &body.stops,
        &body.vehicle_class,
        body.code.as_deref(),
    )
    .await?;

    let method = body.payment_method.as_deref().unwrap_or("cash");
    if !matches!(method, "cash" | "wallet" | "corporate") {
        return Err(AppError::bad(
            ErrorCode::InvalidPaymentMethod,
            "payment_method must be 'cash', 'wallet', or 'corporate'",
        ));
    }

    let bargaining_on = crate::flags::is_enabled(&st, crate::flags::BARGAINING, true).await;
    let pricing_mode = match body.pricing_mode.as_deref() {
        Some("bid") if bargaining_on => "bid",
        _ => "instant",
    };

    // Bargaining is a dashboard-toggleable feature; when off, ignore any
    // proposed fare and charge the algorithmic price.
    let offered_fare = if bargaining_on { body.offered_fare } else { None };

    // Bid mode: the rider's fare is decided later, when a bid is accepted
    // (`routes::bidding::accept_bid` reuses this exact clamp-and-split
    // math). The money columns here are just placeholders until then; only
    // `ask_fare` — the rider's starting price — is actually meaningful.
    let ask_fare = (pricing_mode == "bid")
        .then(|| offered_fare.unwrap_or(est.gross_fare).max(est.fare_floor).min(est.fare_ceiling));

    // Bargaining (instant mode only): clamp the rider's proposed fare to
    // [floor, legal ceiling] and recompute the split on the agreed amount.
    let (gross_fare, commission, accident_fund, driver_payout, final_fare, agreed) =
        if pricing_mode == "instant" {
            if let Some(offered) = offered_fare {
                let agreed = offered.max(est.fare_floor).min(est.fare_ceiling);
                let (commission, fund, payout, final_fare) = pricing::split_agreed_fare(
                    agreed,
                    est.discount_amount,
                    st.config.commission_rate,
                );
                (agreed, commission, fund, payout, final_fare, Some(agreed))
            } else {
                (
                    est.gross_fare,
                    est.commission,
                    est.accident_fund,
                    est.driver_payout,
                    est.final_fare,
                    None,
                )
            }
        } else {
            (
                est.gross_fare,
                est.commission,
                est.accident_fund,
                est.driver_payout,
                est.final_fare,
                None,
            )
        };

    // Resolved before opening the transaction — read-only, and a bad/unknown
    // number should never fail the booking, just silently skip the
    // priority-offer step (see `resolve_preferred_driver`'s doc comment).
    let preferred_driver_id = match body.preferred_driver_phone.as_deref() {
        Some(phone) => resolve_preferred_driver(&st.db, claims.sub, phone).await?,
        None => None,
    };

    let mut tx = st.db.begin().await?;

    // Prepaid: a wallet-paid trip requires enough rider credits up front.
    if method == "wallet" {
        let balance = crate::payments::rider_balance(&st.db, claims.sub).await?;
        if balance < final_fare {
            return Err(AppError::bad(
                ErrorCode::InsufficientCredits,
                "insufficient credits for this trip",
            ));
        }
    }
    // Corporate tab: the rider's company wallet must cover the fare + cap.
    if method == "corporate" {
        crate::partner_ledger::corporate_precheck(&st.db, claims.sub, final_fare).await?;
    }

    if let Some(code) = &est.discount_code {
        if let Some((cid,)) = sqlx::query_as::<_, (Uuid,)>(
            "SELECT id FROM campaigns WHERE code = $1 AND audience = 'rider' AND active = true",
        )
        .bind(code)
        .fetch_optional(&mut *tx)
        .await?
        {
            sqlx::query("UPDATE campaigns SET used_count = used_count + 1 WHERE id = $1")
                .bind(cid)
                .execute(&mut *tx)
                .await?;
            sqlx::query(
                "INSERT INTO campaign_redemptions (campaign_id, user_id, amount) VALUES ($1, $2, $3)",
            )
            .bind(cid)
            .bind(claims.sub)
            .bind(est.discount_amount)
            .execute(&mut *tx)
            .await?;
        }
    }

    let trip: Trip = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "INSERT INTO trips (rider_id, vehicle_class, origin_lat, origin_lng, dest_lat, dest_lng, \
            distance_km, duration_secs, gross_fare, discount_code, discount_amount, final_fare, \
            commission, accident_fund, driver_payout, payment_method, stops, pricing_mode, ask_fare, \
            search_radius_km, preferred_driver_id) \
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21) RETURNING {TRIP_COLS}"
    )))
    .bind(claims.sub)
    .bind(&body.vehicle_class)
    .bind(body.origin.lat)
    .bind(body.origin.lng)
    .bind(body.dest.lat)
    .bind(body.dest.lng)
    .bind(est.distance_km)
    .bind(est.duration_secs)
    .bind(gross_fare)
    .bind(&est.discount_code)
    .bind(est.discount_amount)
    .bind(final_fare)
    .bind(commission)
    .bind(accident_fund)
    .bind(driver_payout)
    .bind(method)
    .bind(serde_json::to_value(&body.stops).unwrap_or_else(|_| serde_json::json!([])))
    .bind(pricing_mode)
    .bind(ask_fare)
    .bind(body.radius_km)
    .bind(preferred_driver_id)
    .fetch_one(&mut *tx)
    .await?;

    let trip_json = serde_json::to_value(&trip).map_err(anyhow::Error::from)?;
    idempotency::store(&mut tx, &idem_key, claims.sub, "rides.create", 200, &trip_json).await?;

    tx.commit().await?;

    // Record the bargaining outcome (anchor + bounded agreed fare).
    if let Some(agreed) = agreed {
        if let Err(e) = sqlx::query(
            "INSERT INTO fare_negotiations (trip_id, algo_fare, floor, ceiling, offered_fare, agreed_fare) \
             VALUES ($1, $2, $3, $4, $5, $6)",
        )
        .bind(trip.id)
        .bind(est.gross_fare)
        .bind(est.fare_floor)
        .bind(est.fare_ceiling)
        .bind(body.offered_fare.unwrap_or(agreed))
        .bind(agreed)
        .execute(&st.db)
        .await
        {
            tracing::warn!(trip = %trip.id, error = %e, "fare_negotiations audit insert failed");
        }
    }

    // Kick dispatch immediately (the background loop is the safety net).
    tokio::spawn({
        let st = st.clone();
        let trip_id = trip.id;
        async move {
            if let Err(e) = crate::dispatch::dispatch_trip(&st, trip_id, false).await {
                tracing::warn!(trip = %trip_id, error = %e, "initial dispatch_trip kick failed");
            }
        }
    });

    crate::routes::metrics::track(
        &st.db,
        "ride_requested",
        Some(claims.sub),
        Some("rider"),
        Some(trip.id),
        json!({ "vehicle_class": body.vehicle_class, "payment_method": method, "gross": gross_fare }),
    )
    .await;

    Ok(Json(trip))
}

#[derive(Deserialize)]
struct StatusRequest {
    status: String,
    /// Required when cancelling: why the rider/driver cancelled.
    #[serde(default)]
    reason: Option<String>,
}

/// Everything `update_status` actually does, factored out so the WebSocket
/// handler (`ws.rs`) can accept a `status` frame sent over the already-open
/// trip socket and perform the exact same transition — same validation,
/// same completion/cancellation handling, same order-mirroring, same
/// broadcast — rather than only ever being reachable over HTTP.
pub(crate) async fn do_update_status(
    st: &AppState,
    claims: &crate::auth::Claims,
    id: Uuid,
    status: String,
    reason: Option<String>,
) -> AppResult<Trip> {
    const ALLOWED: [&str; 4] = ["arriving", "in_progress", "completed", "cancelled"];
    if !ALLOWED.contains(&status.as_str()) {
        return Err(AppError::bad(
            ErrorCode::InvalidStatus,
            "invalid status transition",
        ));
    }

    // Completion is its own path, shared with the automatic "arrived at
    // destination" geofence trigger in tracking.rs — see `complete_trip`.
    // Validated here with a plain (non-locking) read since the money-
    // critical part re-validates under its own row lock inside that
    // function; no need to hold this connection's lock across the call.
    if status == "completed" {
        let row: Option<(Uuid, Option<Uuid>, String)> = sqlx::query_as(
            "SELECT rider_id, driver_id, trip_type::text FROM trips WHERE id = $1",
        )
        .bind(id)
        .fetch_optional(&st.db)
        .await?;
        let (rider_id, driver_id, trip_type) = row.ok_or(AppError::NotFound)?;
        if rider_id != claims.sub && driver_id != Some(claims.sub) {
            return Err(AppError::Forbidden);
        }
        // A *parcel-send* delivery (rider sends a parcel P2P) settles through
        // the proof-of-delivery endpoint (OTP + POD + COD) — never the plain
        // status endpoint, so proof is guaranteed before payment. A
        // marketplace-order courier leg (spawned by the merchant service on
        // `POST /v1/internal/delivery-trips`) is also `trip_type='delivery'`
        // but has no `parcel_details`/OTP row at all, since the order itself
        // is the record of what's owed — that one completes normally, or it
        // would have no completion path whatsoever (the POD endpoint 404s
        // without a `parcel_details` row to check against).
        if trip_type == "delivery" {
            let has_parcel: Option<Uuid> =
                sqlx::query_scalar("SELECT trip_id FROM parcel_details WHERE trip_id = $1")
                    .bind(id)
                    .fetch_optional(&st.db)
                    .await?;
            if has_parcel.is_some() {
                return Err(AppError::BadRequest(
                    "complete a delivery via its proof-of-delivery endpoint".into(),
                ));
            }
        }
        let trip = complete_trip(st, id, claims.sub).await?;
        return Ok(trip);
    }

    let mut tx = st.db.begin().await?;
    let row: Option<TripMoney> = sqlx::query_as(
        "SELECT rider_id, driver_id, trip_type::text AS trip_type, status::text AS status, \
                gross_fare, commission, accident_fund, driver_payout, final_fare, payment_method \
         FROM trips WHERE id = $1 FOR UPDATE",
    )
    .bind(id)
    .fetch_optional(&mut *tx)
    .await?;
    let m = row.ok_or(AppError::NotFound)?;
    if m.rider_id != claims.sub && m.driver_id != Some(claims.sub) {
        return Err(AppError::Forbidden);
    }

    // A courier who has already picked up the order can only complete the
    // delivery from here, not cancel it — the package is physically with
    // them, so "cancelled" would leave it in limbo with no clean recovery
    // the way it does before pickup (see the revert-and-redispatch branch
    // below, which only ever applies pre-pickup). Plain rides are
    // deliberately untouched by this — a driver may still need to cancel
    // mid-ride for a genuine safety/emergency reason.
    if status == "cancelled" && m.trip_type == "delivery" && m.status == "in_progress" {
        return Err(AppError::bad(
            ErrorCode::InvalidStatus,
            "a delivery already picked up can only be completed, not cancelled",
        ));
    }

    let ts_col = match status.as_str() {
        "cancelled" => ", cancelled_at = now()",
        _ => "",
    };
    // Who cancelled, for the complaints view.
    let cancelled_by_role = if m.rider_id == claims.sub {
        "rider"
    } else {
        "driver"
    };
    let trip: Trip = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "UPDATE trips SET status = $2::trip_status, updated_at = now(){ts_col}, \
            cancel_reason = CASE WHEN $2 = 'cancelled' THEN $3 ELSE cancel_reason END, \
            cancelled_by = CASE WHEN $2 = 'cancelled' THEN $4 ELSE cancelled_by END, \
            cancelled_by_role = CASE WHEN $2 = 'cancelled' THEN $5 ELSE cancelled_by_role END \
         WHERE id = $1 RETURNING {TRIP_COLS}"
    )))
    .bind(id)
    .bind(&status)
    .bind(&reason)
    .bind(claims.sub)
    .bind(cancelled_by_role)
    .fetch_one(&mut *tx)
    .await?;

    // A marketplace order's `status` otherwise never leaves 'ready' once its
    // courier trip is dispatched — nothing else advances it. Mirror the
    // courier leg onto the order directly (cross-service write into the
    // merchant service's `orders` table, sharing this Postgres instance,
    // same established convention other services already use). Excludes
    // orders already in a terminal state (delivered/cancelled/rejected) so a
    // late-arriving trip status can't clobber one, e.g., cancelled by staff
    // support in the meantime. (`completed` isn't handled here — it never
    // reaches this function anymore, see the early-return above.)
    if m.trip_type == "delivery" && status == "in_progress" {
        sqlx::query(
            "UPDATE orders SET status = 'picked_up', updated_at = now() \
             WHERE trip_id = $1 AND status NOT IN ('delivered', 'cancelled', 'rejected')",
        )
        .bind(id)
        .execute(&mut *tx)
        .await?;
    }

    // A courier cancelling before pickup (the only case that reaches here —
    // the guard above already rejected it once `in_progress`) leaves the
    // order still sitting at the merchant with nobody coming to get it.
    // Revert it back to `ready` and clear `trip_id` so a fresh courier can
    // actually be dispatched, instead of leaving it permanently stuck
    // pointing at a dead trip (`spawn_courier` refuses to run again while
    // `trip_id IS NOT NULL`).
    let mut redispatch_order: Option<(Uuid, Uuid)> = None;
    if m.trip_type == "delivery" && status == "cancelled" {
        redispatch_order = sqlx::query_as(
            "UPDATE orders SET trip_id = NULL, status = 'ready', updated_at = now() \
             WHERE trip_id = $1 AND status NOT IN ('delivered', 'cancelled', 'rejected') \
             RETURNING id, merchant_id",
        )
        .bind(id)
        .fetch_optional(&mut *tx)
        .await?;
    }

    tx.commit().await?;

    // Best-effort, off the request path: neither the merchant notice nor
    // the redispatch attempt should block this response or have any
    // bearing on whether the cancellation itself succeeded.
    if let Some((order_id, merchant_id)) = redispatch_order {
        if let Ok(Some(owner_id)) = sqlx::query_scalar::<_, Option<Uuid>>(
            "SELECT owner_user_id FROM merchants WHERE id = $1",
        )
        .bind(merchant_id)
        .fetch_one(&st.db)
        .await
        {
            crate::notify::send(
                &st.nats,
                owner_id,
                saarathi_core::domain::notif::TRANSACTIONAL,
                "Courier cancelled",
                "Your delivery driver cancelled before pickup — looking for a new one.",
                Some(format!("saarathi://order/{order_id}")),
            )
            .await;
        }
        if !st.config.merchant_service_url.is_empty() {
            let st = st.clone();
            tokio::spawn(async move {
                let client = reqwest::Client::new();
                let res = client
                    .post(format!(
                        "{}/v1/internal/orders/{order_id}/redispatch",
                        st.config.merchant_service_url
                    ))
                    .header("x-internal-secret", &st.config.internal_service_secret)
                    .send()
                    .await;
                if let Err(e) = res {
                    tracing::warn!(order = %order_id, error = %e, "redispatch call to merchant service failed");
                }
            });
        }
    }

    st.hub.publish(
        "trip",
        id,
        json!({ "type": "status", "status": status }).to_string(),
    );
    if status == "cancelled" && m.status != "cancelled" {
        crate::routes::metrics::track(
            &st.db,
            "ride_cancelled",
            Some(claims.sub),
            Some(cancelled_by_role),
            Some(id),
            json!({ "by": cancelled_by_role }),
        )
        .await;
    }
    if m.status.as_str() != status {
        notify_status_change(st, &m, id, claims.sub, &status).await;
    }
    Ok(trip)
}

async fn update_status(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
    Json(body): Json<StatusRequest>,
) -> AppResult<Json<Trip>> {
    let trip = do_update_status(&st, &claims, id, body.status, body.reason).await?;
    Ok(Json(trip))
}

/// Marks a trip completed — settlement, delivery/order-sync, hub publish,
/// metrics, and the "Trip completed" notify. The one path both the manual
/// `update_status` handler and the automatic "arrived at destination"
/// geofence trigger (`tracking.rs::post_location`) go through, so this
/// money-critical logic never has two implementations to drift apart.
/// Idempotent — a trip already completed is returned as-is (under its own
/// row lock), so a manual "Complete trip" tap racing the auto-trigger can't
/// double-settle. `actor` drives who the "Trip completed" notify goes to
/// (whichever side didn't act) — pass the caller's own id for a manual
/// completion, or the driver's id for the automatic one.
pub(crate) async fn complete_trip(st: &AppState, id: Uuid, actor: Uuid) -> AppResult<Trip> {
    let mut tx = st.db.begin().await?;
    let row: Option<TripMoney> = sqlx::query_as(
        "SELECT rider_id, driver_id, trip_type::text AS trip_type, status::text AS status, \
                gross_fare, commission, accident_fund, driver_payout, final_fare, payment_method \
         FROM trips WHERE id = $1 FOR UPDATE",
    )
    .bind(id)
    .fetch_optional(&mut *tx)
    .await?;
    let m = row.ok_or(AppError::NotFound)?;
    if m.status == "completed" {
        drop(tx);
        let trip: Trip = sqlx::query_as(sqlx::AssertSqlSafe(format!("SELECT {TRIP_COLS} FROM trips WHERE id = $1")))
            .bind(id)
            .fetch_one(&st.db)
            .await?;
        return Ok(trip);
    }

    let trip: Trip = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "UPDATE trips SET status = 'completed', updated_at = now(), completed_at = now() \
         WHERE id = $1 RETURNING {TRIP_COLS}"
    )))
    .bind(id)
    .fetch_one(&mut *tx)
    .await?;

    crate::settle::on_completion(
        st,
        &mut tx,
        id,
        &crate::settle::Completion {
            rider_id: m.rider_id,
            driver_id: m.driver_id,
            gross_fare: m.gross_fare,
            commission: m.commission,
            accident_fund: m.accident_fund,
            driver_payout: m.driver_payout,
            final_fare: m.final_fare,
            payment_method: m.payment_method.clone(),
            vehicle_class: trip.vehicle_class.clone(),
        },
    )
    .await?;

    if m.trip_type == "delivery" {
        sqlx::query(
            "UPDATE orders SET status = 'delivered', updated_at = now() \
             WHERE trip_id = $1 AND status NOT IN ('delivered', 'cancelled', 'rejected')",
        )
        .bind(id)
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;

    st.hub.publish(
        "trip",
        id,
        json!({ "type": "status", "status": "completed" }).to_string(),
    );
    crate::routes::metrics::track(
        &st.db,
        "ride_completed",
        m.driver_id,
        Some("driver"),
        Some(id),
        json!({ "gross": m.gross_fare, "payment_method": m.payment_method }),
    )
    .await;
    notify_status_change(st, &m, id, actor, "completed").await;

    Ok(trip)
}

/// Notify whichever side of the trip didn't just act — a status change is
/// always something that happens *to* the other party, not to the one who
/// triggered it (a driver marking "arriving" is news to the rider, not to
/// themselves). Fire-and-forget: never blocks or fails the status update.
async fn notify_status_change(
    st: &AppState,
    m: &TripMoney,
    trip_id: Uuid,
    actor: Uuid,
    status: &str,
) {
    let Some(driver_id) = m.driver_id else { return };
    let link = Some(format!("saarathi://trip/{trip_id}"));
    match status {
        "arriving" => {
            // Enrich with the driver's actual vehicle so the rider can spot
            // them on the street, not just a generic "driver is close" ping.
            let vehicle: Option<(String, String, String)> = sqlx::query_as(
                "SELECT v.class::text, COALESCE(v.model, ''), COALESCE(v.plate_number, '') \
                 FROM vehicles v JOIN drivers d ON d.id = v.driver_id \
                 WHERE d.user_id = $1",
            )
            .bind(driver_id)
            .fetch_optional(&st.db)
            .await
            .ok()
            .flatten();
            let body = match vehicle {
                Some((_, model, plate)) if !plate.is_empty() => {
                    let model = if model.is_empty() { "vehicle".to_string() } else { model };
                    format!("Your driver is arriving on {model} ({plate}).")
                }
                _ => "Your driver is arriving at your pickup point.".to_string(),
            };
            crate::notify::send(
                &st.nats,
                m.rider_id,
                saarathi_core::domain::notif::TRANSACTIONAL,
                "Driver arriving",
                &body,
                link.clone(),
            )
            .await;
        }
        "in_progress" => {
            crate::notify::send(
                &st.nats,
                m.rider_id,
                saarathi_core::domain::notif::TRANSACTIONAL,
                "Trip started",
                "Your trip is on its way to the destination.",
                link.clone(),
            )
            .await;
        }
        "completed" => {
            crate::notify::send(
                &st.nats,
                m.rider_id,
                saarathi_core::domain::notif::TRANSACTIONAL,
                "Trip completed",
                "You've arrived. Thanks for riding with Saarathi!",
                link.clone(),
            )
            .await;
        }
        "cancelled" => {
            // Whoever didn't cancel gets told; a driver-less trip only has a rider.
            let recipient = if actor == m.rider_id { Some(driver_id) } else { Some(m.rider_id) };
            if let Some(recipient) = recipient {
                crate::notify::send(
                    &st.nats,
                    recipient,
                    saarathi_core::domain::notif::TRANSACTIONAL,
                    "Trip cancelled",
                    "The trip was cancelled.",
                    link.clone(),
                )
                .await;
            }
        }
        _ => {}
    }
}

async fn get_trip(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let trip: Trip = sqlx::query_as(sqlx::AssertSqlSafe(format!("SELECT {TRIP_COLS} FROM trips WHERE id = $1")))
        .bind(id)
        .fetch_optional(&st.db)
        .await?
        .ok_or(AppError::NotFound)?;
    let authorized = trip.rider_id == claims.sub
        || trip.driver_id == Some(claims.sub)
        || claims.is_staff()
        || (trip.trip_type == "delivery" && owns_delivery_merchant(&st, id, claims.sub).await?);
    if !authorized {
        return Err(AppError::Forbidden);
    }
    // Only relevant once completed (rating happens post-trip) — skip the
    // extra query on the hot path this endpoint is on while a trip is
    // still active (polled every few seconds by the tracking screen).
    let rated = if trip.status == "completed" {
        sqlx::query_scalar::<_, Option<Uuid>>(
            "SELECT trip_id FROM ratings WHERE trip_id = $1 AND rater_id = $2",
        )
        .bind(id)
        .bind(claims.sub)
        .fetch_optional(&st.db)
        .await?
        .flatten()
        .is_some()
    } else {
        false
    };
    let mut v = serde_json::to_value(trip).unwrap_or_default();
    v["rated"] = json!(rated);
    Ok(Json(v))
}

/// A delivery trip's courier leg is also visible to the merchant whose order
/// it's fulfilling — they're neither the trip's rider (the customer) nor its
/// driver (the courier), but still need to track their own courier once it's
/// dispatched. Cross-service read against the merchant service's
/// `orders`/`merchants` tables, sharing this Postgres instance — same
/// established convention other services already use against rides-owned
/// tables, just in the other direction here.
async fn owns_delivery_merchant(st: &AppState, trip_id: Uuid, user_id: Uuid) -> AppResult<bool> {
    let owns: Option<Uuid> = sqlx::query_scalar(
        "SELECT m.id FROM orders o JOIN merchants m ON m.id = o.merchant_id \
         WHERE o.trip_id = $1 AND m.owner_user_id = $2",
    )
    .bind(trip_id)
    .bind(user_id)
    .fetch_optional(&st.db)
    .await?;
    Ok(owns.is_some())
}

#[derive(Serialize)]
struct Person {
    name: Option<String>,
    phone: Option<String>,
    rating: Option<f64>,
    rating_count: i64,
}

#[derive(Serialize)]
struct DriverParticipant {
    #[serde(flatten)]
    person: Person,
    vehicle_class: Option<String>,
    make: Option<String>,
    model: Option<String>,
    plate_number: Option<String>,
    color: Option<String>,
    partner_name: Option<String>,
    photo_url: Option<String>,
}

#[derive(Serialize)]
struct Participants {
    rider: Person,
    driver: Option<DriverParticipant>,
}

/// Counterpart identity for the sticky in-trip card: both sides' name/phone/
/// rating, plus the driver's vehicle, fleet-partner name (if any), and photo.
/// Authz mirrors `get_trip` exactly (rider, driver, staff, or — for a
/// delivery trip — the fulfilling merchant) — this is the same trip, just a
/// different projection of it.
async fn get_participants(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Participants>> {
    let trip: Trip = sqlx::query_as(sqlx::AssertSqlSafe(format!("SELECT {TRIP_COLS} FROM trips WHERE id = $1")))
        .bind(id)
        .fetch_optional(&st.db)
        .await?
        .ok_or(AppError::NotFound)?;
    let authorized = trip.rider_id == claims.sub
        || trip.driver_id == Some(claims.sub)
        || claims.is_staff()
        || (trip.trip_type == "delivery" && owns_delivery_merchant(&st, id, claims.sub).await?);
    if !authorized {
        return Err(AppError::Forbidden);
    }

    // Real phone numbers only while the trip is actively underway — never
    // for a still-pending or already-finished trip.
    let phone_visible = matches!(
        trip.status.as_str(),
        "accepted" | "arriving" | "in_progress"
    );

    let rider_row: Option<(Option<String>, Option<String>)> =
        sqlx::query_as("SELECT full_name, phone FROM users WHERE id = $1")
            .bind(trip.rider_id)
            .fetch_optional(&st.db)
            .await?;
    let (rider_name, rider_phone) = rider_row.unwrap_or((None, None));
    let (rider_rating, rider_rating_count): (Option<f64>, i64) = sqlx::query_as(
        "SELECT AVG(stars)::float8, count(*) FROM ratings \
         WHERE ratee_id = $1 AND role = 'driver_rates_rider'",
    )
    .bind(trip.rider_id)
    .fetch_one(&st.db)
    .await?;
    let rider = Person {
        name: rider_name,
        phone: if phone_visible { rider_phone } else { None },
        rating: rider_rating,
        rating_count: rider_rating_count,
    };

    let driver = if let Some(driver_user_id) = trip.driver_id {
        let driver_row: Option<(Option<String>, Option<String>)> =
            sqlx::query_as("SELECT full_name, phone FROM users WHERE id = $1")
                .bind(driver_user_id)
                .fetch_optional(&st.db)
                .await?;
        let (driver_name, driver_phone) = driver_row.unwrap_or((None, None));
        let (driver_rating, driver_rating_count): (Option<f64>, i64) = sqlx::query_as(
            "SELECT AVG(stars)::float8, count(*) FROM ratings \
             WHERE ratee_id = $1 AND role = 'rider_rates_driver'",
        )
        .bind(driver_user_id)
        .fetch_one(&st.db)
        .await?;

        let vehicle: Option<(String, Option<String>, Option<String>, String, Option<String>)> =
            sqlx::query_as(
                "SELECT v.class::text, v.make, v.model, v.plate_number, v.color \
                 FROM vehicles v JOIN drivers d ON d.id = v.driver_id \
                 WHERE d.user_id = $1",
            )
            .bind(driver_user_id)
            .fetch_optional(&st.db)
            .await?;

        let partner_name: Option<String> = sqlx::query_scalar(
            "SELECT p.name FROM partner_drivers pd JOIN partners p ON p.id = pd.partner_id \
             WHERE pd.driver_user_id = $1 AND pd.status = 'active' AND p.status = 'active'",
        )
        .bind(driver_user_id)
        .fetch_optional(&st.db)
        .await?;

        let has_photo: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM driver_documents dd JOIN drivers d ON d.id = dd.driver_id \
             WHERE d.user_id = $1 AND dd.kind = 'profile_photo')",
        )
        .bind(driver_user_id)
        .fetch_one(&st.db)
        .await?;

        Some(DriverParticipant {
            person: Person {
                name: driver_name,
                phone: if phone_visible { driver_phone } else { None },
                rating: driver_rating,
                rating_count: driver_rating_count,
            },
            vehicle_class: vehicle.as_ref().map(|v| v.0.clone()),
            make: vehicle.as_ref().and_then(|v| v.1.clone()),
            model: vehicle.as_ref().and_then(|v| v.2.clone()),
            plate_number: vehicle.as_ref().map(|v| v.3.clone()),
            color: vehicle.as_ref().and_then(|v| v.4.clone()),
            partner_name,
            photo_url: has_photo.then(|| format!("/v1/driver/{driver_user_id}/photo")),
        })
    } else {
        None
    };

    Ok(Json(Participants { rider, driver }))
}

async fn list_mine(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Vec<Value>>> {
    let trips: Vec<Trip> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {TRIP_COLS} FROM trips WHERE rider_id = $1 OR driver_id = $1 ORDER BY created_at DESC LIMIT 100"
    )))
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;

    // Whether *this caller* already rated each trip — the Activity tab uses
    // it to gate retroactive rating and the pending-reviews count. A second
    // query rather than a join on TRIP_COLS-based queries generally, since
    // that const is shared across many call sites that don't have (or want)
    // a per-caller EXISTS subquery.
    let trip_ids: Vec<Uuid> = trips.iter().map(|t| t.id).collect();
    let rated_ids: Vec<Uuid> =
        sqlx::query_scalar("SELECT trip_id FROM ratings WHERE rater_id = $1 AND trip_id = ANY($2)")
            .bind(claims.sub)
            .bind(&trip_ids)
            .fetch_all(&st.db)
            .await?;

    let out = trips
        .into_iter()
        .map(|t| {
            let rated = rated_ids.contains(&t.id);
            let mut v = serde_json::to_value(t).unwrap_or_default();
            v["rated"] = json!(rated);
            v
        })
        .collect();
    Ok(Json(out))
}

/// Self-service mirror of the staff-only `rider_detail` aggregate
/// (`insights.rs`) — same shape, gated to the caller's own id instead of a
/// staff-picked `Path(id)`, and without the account-metadata/recent-trips
/// fields that only make sense in a staff detail view (the Activity tab
/// already covers "my recent trips").
async fn my_stats(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Value>> {
    let (total_rides, completed_rides, cancelled_rides, total_spend, total_distance_km): (
        i64,
        i64,
        i64,
        Decimal,
        Decimal,
    ) = sqlx::query_as(
        "SELECT count(*), \
                count(*) FILTER (WHERE status = 'completed'), \
                count(*) FILTER (WHERE status = 'cancelled'), \
                COALESCE(SUM(final_fare) FILTER (WHERE status = 'completed'), 0), \
                COALESCE(SUM(distance_km) FILTER (WHERE status = 'completed'), 0) \
         FROM trips WHERE rider_id = $1",
    )
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await?;

    // The rating the rider has *received* from drivers, not given.
    let (avg_rating, rating_count): (Option<f64>, i64) = sqlx::query_as(
        "SELECT AVG(stars)::float8, count(*) FROM ratings \
         WHERE ratee_id = $1 AND role = 'driver_rates_rider'",
    )
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await?;

    Ok(Json(json!({
        "total_rides": total_rides,
        "completed_rides": completed_rides,
        "cancelled_rides": cancelled_rides,
        "total_spend": total_spend,
        "total_distance_km": total_distance_km,
        "avg_rating": avg_rating,
        "rating_count": rating_count,
    })))
}

#[derive(sqlx::FromRow)]
struct DriverGoalCampaign {
    id: Uuid,
    title: String,
    kind: String,
    value: Decimal,
    rules: sqlx::types::Json<Vec<crate::rules::CampaignRule>>,
}

/// A driver's progress today toward any live "complete N rides today"
/// campaign — the app-facing counterpart to the automatic bonus payout in
/// `bonus.rs`. Purely informational; the bonus itself is still granted at
/// trip-completion time, not by this endpoint.
async fn driver_today(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Value>> {
    let rides_today = crate::rules::rides_today(&st.db, claims.sub, "driver").await;

    let candidates: Vec<DriverGoalCampaign> = sqlx::query_as(
        "SELECT id, title, kind::text, value, rules FROM campaigns \
         WHERE audience = 'driver' AND active = true \
           AND (starts_at IS NULL OR starts_at <= now()) \
           AND (ends_at IS NULL OR ends_at >= now())",
    )
    .fetch_all(&st.db)
    .await?;

    let goals: Vec<Value> = candidates
        .into_iter()
        .filter_map(|c| {
            let target = c.rules.0.iter().find_map(|r| match r {
                crate::rules::CampaignRule::RidesToday { count } => Some(*count),
                _ => None,
            })?;
            Some(json!({
                "campaign_id": c.id,
                "title": c.title,
                "target": target,
                "reward_kind": c.kind,
                "reward_value": c.value,
                "achieved": rides_today >= target,
            }))
        })
        .collect();

    Ok(Json(json!({
        "rides_today": rides_today,
        "goals": goals,
    })))
}

#[derive(Deserialize)]
struct EarningsQuery {
    #[serde(default)]
    period: Option<String>,
}

#[derive(Serialize, sqlx::FromRow)]
struct EarningsBucket {
    #[sqlx(rename = "bucket")]
    start: chrono::NaiveDate,
    total: Decimal,
    trips: i64,
}

/// A driver's own earnings (`ledger_entries.driver_payout`), bucketed by
/// Nepal-local day/week/month and gap-filled (a bucket with no trips still
/// appears with `total: 0`, not missing) — same `generate_series` LEFT JOIN
/// shape `metrics.rs`'s admin timeseries endpoint uses, but bucketed on NPT
/// local date (`rules.rs::rides_today`'s pattern) rather than raw UTC,
/// since this is a driver-facing "today/this week" figure. The client
/// derives the trend indicator from the last two buckets itself — no
/// separate current-vs-previous computation needed here.
async fn driver_earnings(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Query(q): Query<EarningsQuery>,
) -> AppResult<Json<Value>> {
    let period = q.period.as_deref().unwrap_or("day");
    let sql = match period {
        "week" => {
            "SELECT d::date AS bucket, \
                    COALESCE(SUM(le.driver_payout) FILTER ( \
                        WHERE date_trunc('week', le.created_at AT TIME ZONE 'Asia/Kathmandu')::date = d::date \
                    ), 0) AS total, \
                    COUNT(le.seq) FILTER ( \
                        WHERE date_trunc('week', le.created_at AT TIME ZONE 'Asia/Kathmandu')::date = d::date \
                    ) AS trips \
             FROM generate_series( \
                    date_trunc('week', (now() AT TIME ZONE 'Asia/Kathmandu'))::date - interval '7 weeks', \
                    date_trunc('week', (now() AT TIME ZONE 'Asia/Kathmandu'))::date, \
                    interval '1 week') d \
             LEFT JOIN ledger_entries le \
               ON le.driver_id = $1 \
              AND date_trunc('week', le.created_at AT TIME ZONE 'Asia/Kathmandu')::date \
                    >= date_trunc('week', (now() AT TIME ZONE 'Asia/Kathmandu'))::date - interval '7 weeks' \
             GROUP BY d ORDER BY d"
        }
        "month" => {
            "SELECT d::date AS bucket, \
                    COALESCE(SUM(le.driver_payout) FILTER ( \
                        WHERE date_trunc('month', le.created_at AT TIME ZONE 'Asia/Kathmandu')::date = d::date \
                    ), 0) AS total, \
                    COUNT(le.seq) FILTER ( \
                        WHERE date_trunc('month', le.created_at AT TIME ZONE 'Asia/Kathmandu')::date = d::date \
                    ) AS trips \
             FROM generate_series( \
                    date_trunc('month', (now() AT TIME ZONE 'Asia/Kathmandu'))::date - interval '5 months', \
                    date_trunc('month', (now() AT TIME ZONE 'Asia/Kathmandu'))::date, \
                    interval '1 month') d \
             LEFT JOIN ledger_entries le \
               ON le.driver_id = $1 \
              AND date_trunc('month', le.created_at AT TIME ZONE 'Asia/Kathmandu')::date \
                    >= date_trunc('month', (now() AT TIME ZONE 'Asia/Kathmandu'))::date - interval '5 months' \
             GROUP BY d ORDER BY d"
        }
        _ => {
            "SELECT d::date AS bucket, \
                    COALESCE(SUM(le.driver_payout) FILTER ( \
                        WHERE (le.created_at AT TIME ZONE 'Asia/Kathmandu')::date = d::date \
                    ), 0) AS total, \
                    COUNT(le.seq) FILTER ( \
                        WHERE (le.created_at AT TIME ZONE 'Asia/Kathmandu')::date = d::date \
                    ) AS trips \
             FROM generate_series( \
                    (now() AT TIME ZONE 'Asia/Kathmandu')::date - interval '6 days', \
                    (now() AT TIME ZONE 'Asia/Kathmandu')::date, \
                    interval '1 day') d \
             LEFT JOIN ledger_entries le \
               ON le.driver_id = $1 \
              AND (le.created_at AT TIME ZONE 'Asia/Kathmandu')::date \
                    >= (now() AT TIME ZONE 'Asia/Kathmandu')::date - interval '6 days' \
             GROUP BY d ORDER BY d"
        }
    };

    let buckets: Vec<EarningsBucket> = sqlx::query_as(sql)
        .bind(claims.sub)
        .fetch_all(&st.db)
        .await?;

    Ok(Json(json!({
        "period": period,
        "buckets": buckets,
    })))
}
