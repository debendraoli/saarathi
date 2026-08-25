//! Shared routing primitives used by the routing service **and** its clients.
//!
//! Only fare distance/duration — no POIs, no turn-by-turn. The wire types here
//! are what `saarathi-routing` accepts/returns and what `rides` sends; the
//! haversine fallback keeps fares working when the router is unreachable.

use rust_decimal::prelude::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
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

#[cfg(test)]
mod tests {
    use super::*;

    fn pt(lat: f64, lng: f64) -> LatLng {
        LatLng { lat, lng }
    }

    #[test]
    fn haversine_km_is_zero_for_the_same_point() {
        let p = pt(27.7172, 85.3240);
        assert!(haversine_km(p, p) < 1e-9);
    }

    #[test]
    fn haversine_km_matches_a_known_distance() {
        // One degree of latitude along a meridian is exactly (2*pi*R)/360 —
        // an analytically checkable distance, unlike an eyeballed city pair.
        let a = pt(27.0, 85.0);
        let b = pt(28.0, 85.0);
        let expected = 2.0 * std::f64::consts::PI * 6371.0 / 360.0;
        let d = haversine_km(a, b);
        assert!((d - expected).abs() < 0.5, "got {d}km, expected ~{expected}km");
    }

    #[test]
    fn haversine_km_is_symmetric() {
        let a = pt(27.7172, 85.3240);
        let b = pt(27.7000, 85.3000);
        assert!((haversine_km(a, b) - haversine_km(b, a)).abs() < 1e-9);
    }

    #[test]
    fn haversine_path_with_fewer_than_two_points_is_a_zero_none_result() {
        let r = haversine_path(&[pt(27.7, 85.3)], 1.3, 22.0);
        assert_eq!(r.distance_km, Decimal::ZERO);
        assert_eq!(r.duration_secs, 0);
        assert_eq!(r.source, "none");
        assert!(r.geometry.is_empty());
    }

    #[test]
    fn haversine_path_applies_the_road_factor_and_sums_legs() {
        let a = pt(27.70, 85.30);
        let b = pt(27.71, 85.30);
        let c = pt(27.72, 85.30);
        let direct = haversine_km(a, c);
        let via_b = haversine_km(a, b) + haversine_km(b, c);
        // Sanity: routing through a waypoint on the same line is ~the direct
        // distance, not the direct distance again per leg.
        assert!((direct - via_b).abs() < 1e-6);

        let r = haversine_path(&[a, b, c], 1.3, 22.0);
        let expected = Decimal::from_f64(via_b * 1.3).unwrap().round_dp(3);
        assert_eq!(r.distance_km, expected);
        assert_eq!(r.source, "haversine");
        assert_eq!(r.geometry, vec![a, b, c]); // offline fallback: straight-line shape
    }

    #[test]
    fn haversine_path_duration_scales_inversely_with_speed() {
        let a = pt(27.70, 85.30);
        let b = pt(27.80, 85.30);
        let slow = haversine_path(&[a, b], 1.0, 10.0);
        let fast = haversine_path(&[a, b], 1.0, 40.0);
        assert!(slow.duration_secs > fast.duration_secs);
    }

    #[test]
    fn haversine_path_zero_speed_yields_zero_duration_not_a_div_by_zero_panic() {
        let r = haversine_path(&[pt(27.7, 85.3), pt(27.8, 85.3)], 1.0, 0.0);
        assert_eq!(r.duration_secs, 0);
    }

    #[test]
    fn route_profile_from_wire_maps_four_and_three_wheeler_to_auto() {
        assert_eq!(RouteProfile::from_wire("four_wheeler"), RouteProfile::Auto);
        assert_eq!(RouteProfile::from_wire("three_wheeler"), RouteProfile::Auto);
        assert_eq!(RouteProfile::from_wire("car"), RouteProfile::Auto);
        assert_eq!(RouteProfile::from_wire("auto"), RouteProfile::Auto);
    }

    #[test]
    fn route_profile_from_wire_defaults_unknown_values_to_motorcycle() {
        assert_eq!(RouteProfile::from_wire("two_wheeler"), RouteProfile::Motorcycle);
        assert_eq!(RouteProfile::from_wire("bogus"), RouteProfile::Motorcycle);
        assert_eq!(RouteProfile::from_wire(""), RouteProfile::Motorcycle);
    }

    #[test]
    fn route_profile_wire_round_trips() {
        assert_eq!(RouteProfile::from_wire(RouteProfile::Auto.as_wire()), RouteProfile::Auto);
        assert_eq!(RouteProfile::from_wire(RouteProfile::Motorcycle.as_wire()), RouteProfile::Motorcycle);
    }
}
