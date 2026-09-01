//! Core ride lifecycle: create, fetch, status transitions, participants.

use super::shared::RideRequest;
use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::models::{TRIP_COLS, Trip};
use crate::pricing;
use crate::state::AppState;
use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;
use axum::Json;
use rust_decimal::Decimal;
use saarathi_core::api::ErrorCode;
use saarathi_core::domain::{trip_status, trip_type};
use saarathi_core::idempotency::{self, Reservation};
use serde::Deserialize;
use serde::Serialize;
use serde_json::{Value, json};
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
    let driver_id: Option<Uuid> =
        sqlx::query_scalar("SELECT id FROM users WHERE phone = $1 AND role = 'driver'")
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

const MAX_RIDER_CANCELS_PER_WINDOW: i64 = 3;
const RIDER_CANCEL_WINDOW_HOURS: i32 = 24;

pub(super) async fn create(
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

    let idem_key = saarathi_core::idempotency::key_from_headers(&headers).ok_or_else(|| {
        AppError::bad(
            ErrorCode::Validation,
            "X-Idempotency-Key header is required",
        )
    })?;

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
    let offered_fare = if bargaining_on {
        body.offered_fare
    } else {
        None
    };

    // Bid mode: the rider's fare is decided later, when a bid is accepted
    // (`routes::bidding::accept_bid` reuses this exact clamp-and-split
    // math). The money columns here are just placeholders until then; only
    // `ask_fare` — the rider's starting price — is actually meaningful.
    let ask_fare = (pricing_mode == "bid").then(|| {
        offered_fare
            .unwrap_or(est.gross_fare)
            .max(est.fare_floor)
            .min(est.fare_ceiling)
    });

    // Bargaining (instant mode only): clamp the rider's proposed fare to
    // [floor, legal ceiling] and recompute the split on the agreed amount.
    let (gross_fare, commission, accident_fund, driver_payout, final_fare, agreed) = if pricing_mode
        == "instant"
    {
        if let Some(offered) = offered_fare {
            let agreed = offered.max(est.fare_floor).min(est.fare_ceiling);
            let (commission, fund, payout, final_fare) =
                pricing::split_agreed_fare(agreed, est.discount_amount, st.config.commission_rate);
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

    if let Some(code) = &est.discount_code
        && let Some((cid,)) = sqlx::query_as::<_, (Uuid,)>(
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
    idempotency::store(
        &mut tx,
        &idem_key,
        claims.sub,
        "rides.create",
        200,
        &trip_json,
    )
    .await?;

    tx.commit().await?;

    // Record the bargaining outcome (anchor + bounded agreed fare).
    if let Some(agreed) = agreed
        && let Err(e) = sqlx::query(
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
pub(super) struct StatusRequest {
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
    const ALLOWED: [&str; 4] = [
        trip_status::ARRIVING,
        trip_status::IN_PROGRESS,
        trip_status::COMPLETED,
        trip_status::CANCELLED,
    ];
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
    if status == trip_status::COMPLETED {
        let row: Option<(Uuid, Option<Uuid>, String)> =
            sqlx::query_as("SELECT rider_id, driver_id, trip_type::text FROM trips WHERE id = $1")
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
        if trip_type == saarathi_core::domain::trip_type::DELIVERY {
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
    if status == trip_status::CANCELLED
        && m.trip_type == trip_type::DELIVERY
        && m.status == trip_status::IN_PROGRESS
    {
        return Err(AppError::bad(
            ErrorCode::InvalidStatus,
            "a delivery already picked up can only be completed, not cancelled",
        ));
    }

    let ts_col = match status.as_str() {
        trip_status::CANCELLED => ", cancelled_at = now()",
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
    if m.trip_type == trip_type::DELIVERY && status == trip_status::IN_PROGRESS {
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
    if m.trip_type == trip_type::DELIVERY && status == trip_status::CANCELLED {
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
    if status == trip_status::CANCELLED && m.status != trip_status::CANCELLED {
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

pub(super) async fn update_status(
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
    if m.status == trip_status::COMPLETED {
        drop(tx);
        let trip: Trip = sqlx::query_as(sqlx::AssertSqlSafe(format!(
            "SELECT {TRIP_COLS} FROM trips WHERE id = $1"
        )))
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

    if m.trip_type == trip_type::DELIVERY {
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
        json!({ "type": "status", "status": trip_status::COMPLETED }).to_string(),
    );
    // Both are fire-and-forget (a metrics event and a push notification) and
    // run strictly after the settlement transaction above already committed
    // — nothing money-related is deferred, so it's safe to background them
    // instead of adding their latency to the caller's response.
    {
        let st = st.clone();
        tokio::spawn(async move {
            crate::routes::metrics::track(
                &st.db,
                "ride_completed",
                m.driver_id,
                Some("driver"),
                Some(id),
                json!({ "gross": m.gross_fare, "payment_method": m.payment_method }),
            )
            .await;
            notify_status_change(&st, &m, id, actor, trip_status::COMPLETED).await;
        });
    }

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
        trip_status::ARRIVING => {
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
                    let model = if model.is_empty() {
                        "vehicle".to_string()
                    } else {
                        model
                    };
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
        trip_status::IN_PROGRESS => {
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
        trip_status::COMPLETED => {
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
        trip_status::CANCELLED => {
            // Whoever didn't cancel gets told; a driver-less trip only has a rider.
            let recipient = if actor == m.rider_id {
                Some(driver_id)
            } else {
                Some(m.rider_id)
            };
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

pub(super) async fn get_trip(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let mut trip: Trip = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {TRIP_COLS} FROM trips WHERE id = $1"
    )))
    .bind(id)
    .fetch_optional(&st.db)
    .await?
    .ok_or(AppError::NotFound)?;
    if trip.pricing_mode == "bid"
        && let Ok(vclass) = pricing::parse_vehicle_class(&trip.vehicle_class)
    {
        trip.ask_ceiling = Some(saarathi_core::pricing::legal_ceiling(
            vclass,
            trip.distance_km,
        ));
    }
    let authorized = trip.rider_id == claims.sub
        || trip.driver_id == Some(claims.sub)
        || claims.is_staff()
        || (trip.trip_type == trip_type::DELIVERY
            && owns_delivery_merchant(&st, id, claims.sub).await?);
    if !authorized {
        return Err(AppError::Forbidden);
    }
    // Only relevant once completed (rating happens post-trip) — skip the
    // extra query on the hot path this endpoint is on while a trip is
    // still active (polled every few seconds by the tracking screen).
    let rated = if trip.status == trip_status::COMPLETED {
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

#[derive(Serialize, sqlx::FromRow)]
struct MerchantParticipant {
    name: String,
    address: Option<String>,
    phone: Option<String>,
}

#[derive(Serialize)]
pub(super) struct Participants {
    rider: Person,
    driver: Option<DriverParticipant>,
    /// Set only for a `trip_type = 'delivery'` trip — the merchant the
    /// courier is fetching the order from. The client shows this instead of
    /// `rider` while the courier's on the pickup leg (`accepted`/`arriving`,
    /// heading to this trip's `origin`, which *is* the merchant's location
    /// for a delivery trip); once `in_progress` (courier has the order,
    /// heading to `dest`), it switches to `rider` — the actual delivery
    /// recipient — same as it always has.
    #[serde(skip_serializing_if = "Option::is_none")]
    merchant: Option<MerchantParticipant>,
}

/// Counterpart identity for the sticky in-trip card: both sides' name/phone/
/// rating, plus the driver's vehicle, fleet-partner name (if any), and photo.
/// Authz mirrors `get_trip` exactly (rider, driver, staff, or — for a
/// delivery trip — the fulfilling merchant) — this is the same trip, just a
/// different projection of it.
pub(super) async fn get_participants(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Participants>> {
    let trip: Trip = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {TRIP_COLS} FROM trips WHERE id = $1"
    )))
    .bind(id)
    .fetch_optional(&st.db)
    .await?
    .ok_or(AppError::NotFound)?;
    let authorized = trip.rider_id == claims.sub
        || trip.driver_id == Some(claims.sub)
        || claims.is_staff()
        || (trip.trip_type == trip_type::DELIVERY
            && owns_delivery_merchant(&st, id, claims.sub).await?);
    if !authorized {
        return Err(AppError::Forbidden);
    }

    // Real phone numbers only while the trip is actively underway — never
    // for a still-pending or already-finished trip.
    let phone_visible = matches!(
        trip.status.as_str(),
        trip_status::ACCEPTED | trip_status::ARRIVING | trip_status::IN_PROGRESS
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

        // `(class, make, model, plate_number, color)`, in `SELECT` order below.
        type VehicleRow = (
            String,
            Option<String>,
            Option<String>,
            String,
            Option<String>,
        );
        let vehicle: Option<VehicleRow> = sqlx::query_as(
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

    // Cross-service read against the merchant service's own tables (shared
    // Postgres instance) — same established convention as the rating-status
    // lookups above and `merchant::my_orders`'s own reverse read against
    // this service's `ratings` table.
    let merchant: Option<MerchantParticipant> = if trip.trip_type == trip_type::DELIVERY {
        sqlx::query_as(
            "SELECT m.name, m.address, m.phone FROM orders o \
             JOIN merchants m ON m.id = o.merchant_id WHERE o.trip_id = $1",
        )
        .bind(id)
        .fetch_optional(&st.db)
        .await?
    } else {
        None
    };

    Ok(Json(Participants {
        rider,
        driver,
        merchant,
    }))
}

/// Offset pagination for a list endpoint — `limit` capped well below what a
/// single response should ever carry, `offset` unbounded (a deep scroll is
/// just a slower query, not a correctness issue). Duplicated per-service
/// rather than shared, same as `audit_record`/`validate_service_types` —
/// each service already has its own small copy of this class of helper
/// rather than a new cross-service dependency for a few lines.
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

pub(super) async fn list_mine(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Query(page): Query<PageQuery>,
) -> AppResult<Json<Vec<Value>>> {
    let trips: Vec<Trip> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {TRIP_COLS} FROM trips WHERE rider_id = $1 OR driver_id = $1 ORDER BY created_at DESC LIMIT $2 OFFSET $3"
    )))
    .bind(claims.sub)
    .bind(page.limit())
    .bind(page.offset())
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
