//! Service-to-service API — **not** registered in the gateway (see
//! `backend/traefik/dynamic/routes.yml`; mirrors how `saarathi-routing` is
//! reachable only inside the docker network, never publicly). This is the
//! explicit boundary `saarathi-merchant` calls through instead of reaching
//! into rides' dispatch/settlement internals directly, per the Phase 2 brief:
//! "Decouple `merchant` domain into its own crate/service with a clear API
//! boundary." Guarded by a shared secret (`INTERNAL_SERVICE_SECRET`) since,
//! unlike routing's stateless computation, this one creates real trips.

use crate::error::{AppError, AppResult};
use crate::models::{TRIP_COLS, Trip};
use crate::routing::{LatLng, RouteProfile};
use crate::state::AppState;
use axum::extract::{Query, State};
use axum::http::HeaderMap;
use axum::{
    Json, Router,
    routing::{get, post},
};
use rust_decimal::Decimal;
use saarathi_core::domain::trip_type;
use saarathi_core::money::Money;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/internal/delivery-trips", post(create_delivery_trip))
        .route("/v1/internal/nearby-drivers", get(nearby_drivers))
}

fn check_internal_secret(st: &AppState, headers: &HeaderMap) -> AppResult<()> {
    if saarathi_core::api::check_internal_secret(&st.config.internal_service_secret, headers) {
        Ok(())
    } else {
        Err(AppError::Forbidden)
    }
}

#[derive(Deserialize)]
struct CreateDeliveryTrip {
    rider_id: Uuid,
    origin: LatLng,
    dest: LatLng,
    /// Already computed by the caller (e.g. merchant service's delivery-fee
    /// calc) — this endpoint doesn't re-derive it, only splits + settles it.
    gross_fare: Decimal,
    payment_method: String,
}

#[derive(Serialize)]
struct CreateDeliveryTripResponse {
    trip_id: Uuid,
}

/// Create (and immediately attempt to dispatch) a `trip_type='delivery'`
/// trip — the same courier leg every parcel/marketplace delivery rides on.
async fn create_delivery_trip(
    State(st): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<CreateDeliveryTrip>,
) -> AppResult<Json<CreateDeliveryTripResponse>> {
    check_internal_secret(&st, &headers)?;

    // Circuit breaker: ops can freeze delivery intake from the dashboard —
    // same pattern as rides.rs::create's RIDES_NEW_REQUESTS check.
    if !crate::flags::is_enabled(&st, crate::flags::DELIVERY, true).await {
        return Err(AppError::disabled(
            "delivery is temporarily paused; please try again shortly",
        ));
    }

    let route = st
        .router
        .route_path(&[body.origin, body.dest], RouteProfile::Motorcycle)
        .await;
    let (commission, accident_fund, driver_payout) = saarathi_core::pricing::split_fare(
        Money::from_decimal(body.gross_fare),
        st.config.commission_rate,
    );

    let trip: Trip = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "INSERT INTO trips (rider_id, trip_type, vehicle_class, origin_lat, origin_lng, \
            dest_lat, dest_lng, distance_km, duration_secs, gross_fare, discount_amount, \
            final_fare, commission, accident_fund, driver_payout, payment_method) \
         VALUES ($1,'delivery','two_wheeler',$2,$3,$4,$5,$6,$7,$8,0,$8,$9,$10,$11,$12) \
         RETURNING {TRIP_COLS}"
    )))
    .bind(body.rider_id)
    .bind(body.origin.lat)
    .bind(body.origin.lng)
    .bind(body.dest.lat)
    .bind(body.dest.lng)
    .bind(route.distance_km)
    .bind(route.duration_secs)
    .bind(body.gross_fare)
    .bind(commission.amount())
    .bind(accident_fund.amount())
    .bind(driver_payout.amount())
    .bind(&body.payment_method)
    .fetch_one(&st.db)
    .await?;

    tokio::spawn({
        let st = st.clone();
        let trip_id = trip.id;
        async move {
            let _ = crate::dispatch::dispatch_trip(&st, trip_id, false).await;
        }
    });

    Ok(Json(CreateDeliveryTripResponse { trip_id: trip.id }))
}

#[derive(Deserialize)]
struct NearbyDriversQuery {
    lat: f64,
    lng: f64,
    /// "ride" or "delivery" — which drivers count as "nearby" for the
    /// caller's purpose. Defaults to "delivery" since the only current
    /// caller is the merchant service's courier-availability check.
    #[serde(default = "default_job_type")]
    job_type: String,
}

fn default_job_type() -> String {
    trip_type::DELIVERY.to_string()
}

#[derive(Serialize)]
struct NearbyDriversResponse {
    count: usize,
}

/// Lets `saarathi-merchant` warn a merchant marking an order "ready" (the
/// moment a courier is actually needed — see `spawn_courier`) when no
/// courier is likely to be dispatched soon, using the exact same "nearby"
/// definition the app's own ride-booking gate and the supply-surge signal
/// already use, filtered to drivers who actually accept that job type.
async fn nearby_drivers(
    State(st): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<NearbyDriversQuery>,
) -> AppResult<Json<NearbyDriversResponse>> {
    check_internal_secret(&st, &headers)?;
    let count = crate::dispatch::nearby_count(
        &st,
        q.lng,
        q.lat,
        st.config.dispatch_max_radius_km,
        &q.job_type,
    )
    .await
    .unwrap_or(0);
    Ok(Json(NearbyDriversResponse { count }))
}
