//! Shared routing primitives used by the routing service **and** its clients.
//!
//! Only fare distance/duration — no POIs, no turn-by-turn. The wire types here
//! are what `saarathi-routing` accepts/returns and what `rides` sends; the
//! haversine fallback keeps fares working when the router is unreachable.

use rust_decimal::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct LatLng {
    pub lat: f64,
    pub lng: f64,
}

/// Vehicle profile → routing costing model. Two-wheelers can use lanes/paths
/// cars can't, so motorbike distances differ from car distances.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RouteProfile {
    Motorcycle,
    Auto,
}

impl RouteProfile {
    /// Stable wire value (also the Valhalla costing name).
    pub fn as_wire(self) -> &'static str {
        match self {
            RouteProfile::Motorcycle => "motorcycle",
            RouteProfile::Auto => "auto",
        }
    }

    pub fn from_wire(s: &str) -> Self {
        match s {
            "auto" | "car" | "four_wheeler" | "three_wheeler" => RouteProfile::Auto,
            _ => RouteProfile::Motorcycle,
        }
    }
}

/// A request to measure an ordered path (origin, waypoints…, destination).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RouteRequest {
    pub points: Vec<LatLng>,
    /// Wire value of [`RouteProfile`] — "motorcycle" | "auto".
    pub profile: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RouteResult {
    pub distance_km: Decimal,
    pub duration_secs: i32,
    /// Ordered road-shape geometry for drawing the route on a map. Empty when
    /// unavailable (e.g. the engine returned only a summary).
    #[serde(default)]
    pub geometry: Vec<LatLng>,
    /// Which method produced this: "valhalla" | "osrm" | "haversine" | "none".
    pub source: String,
}

/// Haversine sum over the legs — the offline-safe fallback. `road_factor`
/// approximates real road distance from straight-line; `avg_speed_kmh` estimates
/// duration.
pub fn haversine_path(points: &[LatLng], road_factor: f64, avg_speed_kmh: f64) -> RouteResult {
    if points.len() < 2 {
        return RouteResult {
            distance_km: Decimal::ZERO,
            duration_secs: 0,
            geometry: Vec::new(),
            source: "none".into(),
        };
    }
    let mut road = 0.0;
    for leg in points.windows(2) {
        road += haversine_km(leg[0], leg[1]) * road_factor;
    }
    let secs = if avg_speed_kmh > 0.0 {
        (road / avg_speed_kmh * 3600.0).round() as i32
    } else {
        0
    };
    RouteResult {
        distance_km: Decimal::from_f64(road).unwrap_or_default().round_dp(3),
        duration_secs: secs,
        // No road shape offline — fall back to the straight-line path so the map
        // still draws something sensible.
        geometry: points.to_vec(),
        source: "haversine".into(),
    }
}

/// Great-circle distance between two points, in km.
pub fn haversine_km(a: LatLng, b: LatLng) -> f64 {
    const R: f64 = 6371.0;
    let (lat1, lat2) = (a.lat.to_radians(), b.lat.to_radians());
    let dlat = (b.lat - a.lat).to_radians();
    let dlng = (b.lng - a.lng).to_radians();
    let h = (dlat / 2.0).sin().powi(2) + lat1.cos() * lat2.cos() * (dlng / 2.0).sin().powi(2);
    2.0 * R * h.sqrt().asin()
}

/// Thin HTTP client for **saarathi-routing**, shared by every service that
/// needs a road distance/duration (`rides`, `merchant`). On any failure
/// (service down, timeout, unconfigured) falls back to the local haversine
/// estimate so fares/fees keep working offline.
pub struct RoutingClient {
    /// Base URL of the routing service, e.g. http://localhost:8084. Empty =
    /// local haversine only.
    service_url: String,
    road_factor: f64,
    avg_speed_kmh: f64,
    http: reqwest::Client,
}

impl RoutingClient {
    pub fn new(service_url: String, road_factor: f64, avg_speed_kmh: f64) -> Self {
        RoutingClient {
            service_url: service_url.trim_end_matches('/').to_string(),
            road_factor,
            avg_speed_kmh,
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(5))
                .build()
                .expect("http client"),
        }
    }

    /// Route through an ordered path (origin, waypoints…, dest) for the given
    /// vehicle profile. This is how single- and multi-stop fares are measured.
    pub async fn route_path(&self, points: &[LatLng], profile: RouteProfile) -> RouteResult {
        if points.len() < 2 {
            return RouteResult {
                distance_km: Decimal::ZERO,
                duration_secs: 0,
                geometry: Vec::new(),
                source: "none".into(),
            };
        }
        if !self.service_url.is_empty() {
            match self.call_service(points, profile).await {
                Ok(r) => return r,
                Err(e) => {
                    tracing::warn!(error = %e, "routing service failed; using haversine fallback")
                }
            }
        }
        haversine_path(points, self.road_factor, self.avg_speed_kmh)
    }

    async fn call_service(
        &self,
        points: &[LatLng],
        profile: RouteProfile,
    ) -> anyhow::Result<RouteResult> {
        let req = RouteRequest {
            points: points.to_vec(),
            profile: profile.as_wire().to_string(),
        };
        let resp: RouteResult = self
            .http
            .post(format!("{}/v1/route", self.service_url))
            .json(&req)
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        Ok(resp)
    }
}
