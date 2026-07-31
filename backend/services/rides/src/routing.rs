//! Routing client used **only for fare distance/duration** — no POIs, no
//! turn-by-turn, no nearby search. Tries a self-hosted OSRM/Valhalla server if
//! configured, and falls back to a haversine estimate when the router is
//! unreachable, so fares still work on flaky rural connectivity.

use crate::config::Config;
use rust_decimal::prelude::*;
use serde::{Deserialize, Serialize};
use std::time::Duration;

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct LatLng {
    pub lat: f64,
    pub lng: f64,
}

#[derive(Debug, Clone)]
pub struct RouteResult {
    pub distance_km: Decimal,
    pub duration_secs: i32,
    pub source: &'static str,
}

pub struct Router {
    url: String,
    road_factor: f64,
    avg_speed_kmh: f64,
    http: reqwest::Client,
}

#[derive(Deserialize)]
struct OsrmResponse {
    routes: Vec<OsrmRoute>,
}

#[derive(Deserialize)]
struct OsrmRoute {
    distance: f64, // metres
    duration: f64, // seconds
}

impl Router {
    pub fn new(cfg: &Config) -> Self {
        Router {
            url: cfg.routing_url.trim_end_matches('/').to_string(),
            road_factor: cfg.road_factor.to_f64().unwrap_or(1.3),
            avg_speed_kmh: cfg.avg_speed_kmh.to_f64().unwrap_or(22.0),
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(4))
                .build()
                .expect("http client"),
        }
    }

    pub async fn route(&self, origin: LatLng, dest: LatLng) -> RouteResult {
        if !self.url.is_empty() {
            match self.osrm(origin, dest).await {
                Ok(r) => return r,
                Err(e) => tracing::warn!(error = %e, "routing provider failed; using haversine fallback"),
            }
        }
        self.haversine(origin, dest)
    }

    async fn osrm(&self, o: LatLng, d: LatLng) -> anyhow::Result<RouteResult> {
        // OSRM expects lng,lat order.
        let url = format!(
            "{}/route/v1/driving/{},{};{},{}?overview=false",
            self.url, o.lng, o.lat, d.lng, d.lat
        );
        let resp: OsrmResponse = self.http.get(url).send().await?.error_for_status()?.json().await?;
        let route = resp.routes.into_iter().next().ok_or_else(|| anyhow::anyhow!("no route"))?;
        let km = Decimal::from_f64(route.distance / 1000.0).unwrap_or_default().round_dp(3);
        Ok(RouteResult { distance_km: km, duration_secs: route.duration.round() as i32, source: "osrm" })
    }

    fn haversine(&self, o: LatLng, d: LatLng) -> RouteResult {
        let straight = haversine_km(o, d);
        let road = straight * self.road_factor;
        let secs = if self.avg_speed_kmh > 0.0 {
            (road / self.avg_speed_kmh * 3600.0).round() as i32
        } else {
            0
        };
        RouteResult {
            distance_km: Decimal::from_f64(road).unwrap_or_default().round_dp(3),
            duration_secs: secs,
            source: "haversine",
        }
    }
}

fn haversine_km(a: LatLng, b: LatLng) -> f64 {
    const R: f64 = 6371.0;
    let (lat1, lat2) = (a.lat.to_radians(), b.lat.to_radians());
    let dlat = (b.lat - a.lat).to_radians();
    let dlng = (b.lng - a.lng).to_radians();
    let h = (dlat / 2.0).sin().powi(2) + lat1.cos() * lat2.cos() * (dlng / 2.0).sin().powi(2);
    2.0 * R * h.sqrt().asin()
}
