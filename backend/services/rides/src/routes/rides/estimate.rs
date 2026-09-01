//! Fare estimate + road-following route geometry.

use super::shared::RideRequest;
use crate::auth::AuthUser;
use crate::error::AppResult;
use crate::pricing::{self, Estimate};
use crate::routing::{LatLng, RouteProfile, RouteStep};
use crate::state::AppState;
use axum::extract::State;
use axum::Json;
use rust_decimal::Decimal;
use serde::Deserialize;
use serde::Serialize;

pub(super) async fn estimate(
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
pub(super) struct RouteReq {
    origin: LatLng,
    dest: LatLng,
    #[serde(default)]
    stops: Vec<LatLng>,
    #[serde(default)]
    vehicle_class: Option<String>,
}

#[derive(Serialize)]
pub(super) struct RouteResp {
    distance_km: Decimal,
    duration_secs: i32,
    /// Ordered road-shape points for drawing the route polyline on the map.
    geometry: Vec<LatLng>,
    /// Turn-by-turn maneuvers, in order — empty when the routing engine
    /// couldn't supply them (offline fallback).
    steps: Vec<RouteStep>,
    /// Optimized visiting order for `stops` (pickup/destination always stay
    /// fixed first/last) — index `k` is the original `stops` position that
    /// should be visited `k`-th. Empty means "use the order sent": either
    /// there were fewer than 2 stops, or the routing engine that answered
    /// doesn't support reordering (offline/OSRM fallback).
    stop_order: Vec<usize>,
}

/// Road-following route geometry for the map (pickup → stops → destination).
/// Falls back to a straight line when the routing engine is unreachable.
pub(super) async fn route_geometry(
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
        stop_order: route.stop_order,
    }))
}
