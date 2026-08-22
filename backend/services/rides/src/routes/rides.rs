//! Ride lifecycle + fare estimate endpoints.

use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::models::{Trip, TRIP_COLS};
use crate::pricing::{self, Estimate};
use crate::routing::{LatLng, RouteProfile};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use rust_decimal::Decimal;
use saarathi_core::api::ErrorCode;
use saarathi_core::domain::roles;
use serde::Deserialize;
use serde::Serialize;
use serde_json::json;
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
        .route("/v1/rides/{id}", get(get_trip))
        .route("/v1/rides/{id}/accept", post(accept))
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
    /// Bounded fare bargaining: a rider's proposed fare (clamped to the legal band).
    #[serde(default)]
    offered_fare: Option<Decimal>,
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
    }))
}

async fn create(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<RideRequest>,
) -> AppResult<Json<Trip>> {
    // Circuit breaker: ops can freeze new ride intake from the dashboard.
    if !crate::flags::is_enabled(&st, crate::flags::RIDES_NEW_REQUESTS, true).await {
        return Err(AppError::disabled(
            "ride requests are temporarily paused; please try again shortly",
        ));
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

    // Bargaining is a dashboard-toggleable feature; when off, ignore any
    // proposed fare and charge the algorithmic price.
    let offered_fare = if crate::flags::is_enabled(&st, crate::flags::BARGAINING, true).await {
        body.offered_fare
    } else {
        None
    };

    // Bargaining: clamp the rider's proposed fare to [floor, legal ceiling] and
    // recompute the split on the agreed amount (commission still capped at 10%).
    let (gross_fare, commission, accident_fund, driver_payout, final_fare, agreed) =
        if let Some(offered) = offered_fare {
            let agreed = offered.max(est.fare_floor).min(est.fare_ceiling);
            let commission = (agreed * st.config.commission_rate).round_dp(2);
            let fund = (agreed * Decimal::new(1, 2)).round_dp(2);
            let payout = agreed - commission - fund;
            let final_fare = (agreed - est.discount_amount).max(Decimal::ZERO);
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

    let trip: Trip = sqlx::query_as(&format!(
        "INSERT INTO trips (rider_id, vehicle_class, origin_lat, origin_lng, dest_lat, dest_lng, \
            distance_km, duration_secs, gross_fare, discount_code, discount_amount, final_fare, \
            commission, accident_fund, driver_payout, payment_method, stops) \
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17) RETURNING {TRIP_COLS}"
    ))
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
    .fetch_one(&mut *tx)
    .await?;

    tx.commit().await?;

    // Record the bargaining outcome (anchor + bounded agreed fare).
    if let Some(agreed) = agreed {
        let _ = sqlx::query(
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
        .await;
    }

    // Kick dispatch immediately (the background loop is the safety net).
    tokio::spawn({
        let st = st.clone();
        let trip_id = trip.id;
        async move {
            let _ = crate::dispatch::dispatch_trip(&st, trip_id).await;
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

async fn accept(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Trip>> {
    if claims.role != roles::DRIVER {
        return Err(AppError::Forbidden);
    }
    let trip: Trip = sqlx::query_as(&format!(
        "UPDATE trips SET driver_id = $2, status = 'accepted', accepted_at = now(), updated_at = now() \
         WHERE id = $1 AND status = 'requested' RETURNING {TRIP_COLS}"
    ))
    .bind(id)
    .bind(claims.sub)
    .fetch_optional(&st.db)
    .await?
    .ok_or_else(|| AppError::conflict(ErrorCode::TripUnavailable, "trip is no longer available"))?;

    st.hub.publish(
        id,
        json!({ "type": "status", "status": "accepted", "driver_id": claims.sub }).to_string(),
    );
    Ok(Json(trip))
}

#[derive(Deserialize)]
struct StatusRequest {
    status: String,
    /// Required when cancelling: why the rider/driver cancelled.
    #[serde(default)]
    reason: Option<String>,
}

async fn update_status(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
    Json(body): Json<StatusRequest>,
) -> AppResult<Json<Trip>> {
    const ALLOWED: [&str; 4] = ["arriving", "in_progress", "completed", "cancelled"];
    if !ALLOWED.contains(&body.status.as_str()) {
        return Err(AppError::bad(
            ErrorCode::InvalidStatus,
            "invalid status transition",
        ));
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
    // Deliveries settle through the proof-of-delivery endpoint (OTP + POD + COD),
    // never the plain status endpoint — that guarantees proof before payment.
    if m.trip_type == "delivery" && body.status == "completed" {
        return Err(AppError::BadRequest(
            "complete a delivery via its proof-of-delivery endpoint".into(),
        ));
    }

    let ts_col = match body.status.as_str() {
        "completed" => ", completed_at = now()",
        "cancelled" => ", cancelled_at = now()",
        _ => "",
    };
    // Who cancelled, for the complaints view.
    let cancelled_by_role = if m.rider_id == claims.sub {
        "rider"
    } else {
        "driver"
    };
    let trip: Trip = sqlx::query_as(&format!(
        "UPDATE trips SET status = $2::trip_status, updated_at = now(){ts_col}, \
            cancel_reason = CASE WHEN $2 = 'cancelled' THEN $3 ELSE cancel_reason END, \
            cancelled_by = CASE WHEN $2 = 'cancelled' THEN $4 ELSE cancelled_by END, \
            cancelled_by_role = CASE WHEN $2 = 'cancelled' THEN $5 ELSE cancelled_by_role END \
         WHERE id = $1 RETURNING {TRIP_COLS}"
    ))
    .bind(id)
    .bind(&body.status)
    .bind(&body.reason)
    .bind(claims.sub)
    .bind(cancelled_by_role)
    .fetch_one(&mut *tx)
    .await?;

    // On first completion, append the immutable ledger entry + settle the wallet.
    if body.status == "completed" && m.status != "completed" {
        crate::settle::on_completion(
            &st,
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
    }

    tx.commit().await?;

    st.hub.publish(
        id,
        json!({ "type": "status", "status": body.status }).to_string(),
    );
    if body.status == "completed" && m.status != "completed" {
        crate::routes::metrics::track(
            &st.db,
            "ride_completed",
            m.driver_id,
            Some("driver"),
            Some(id),
            json!({ "gross": m.gross_fare, "payment_method": m.payment_method }),
        )
        .await;
    } else if body.status == "cancelled" && m.status != "cancelled" {
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
    if m.status.as_str() != body.status {
        notify_status_change(&st, &m, id, claims.sub, &body.status).await;
    }
    Ok(Json(trip))
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
                "SELECT class::text, COALESCE(model, ''), COALESCE(plate_number, '') \
                 FROM vehicles WHERE driver_id = $1",
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
) -> AppResult<Json<Trip>> {
    let trip: Trip = sqlx::query_as(&format!("SELECT {TRIP_COLS} FROM trips WHERE id = $1"))
        .bind(id)
        .fetch_optional(&st.db)
        .await?
        .ok_or(AppError::NotFound)?;
    if trip.rider_id != claims.sub && trip.driver_id != Some(claims.sub) && !claims.is_staff() {
        return Err(AppError::Forbidden);
    }
    Ok(Json(trip))
}

async fn list_mine(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Vec<Trip>>> {
    let trips: Vec<Trip> = sqlx::query_as(&format!(
        "SELECT {TRIP_COLS} FROM trips WHERE rider_id = $1 OR driver_id = $1 ORDER BY created_at DESC LIMIT 100"
    ))
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(trips))
}
