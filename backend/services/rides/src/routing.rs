//! Routing client used **only for fare distance/duration** — no POIs, no
//! turn-by-turn, no nearby search.
//!
//! Primary engine is a **self-hosted Valhalla** server (per docs/research/05):
//! free, in-country, and it exposes a `motorcycle` costing that matches our
//! two-wheeler-first launch. A single `/route` call handles the whole multi-stop
//! path. OSRM is still supported as an alternative engine, and when the router is
//! unreachable we fall back to a haversine estimate so fares keep working on
//! flaky rural connectivity.

use crate::config::Config;
use rust_decimal::prelude::*;
use serde::{Deserialize, Serialize};
use std::time::Duration;

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct LatLng {
    pub lat: f64,
    pub lng: f64,
}

/// Vehicle profile → routing costing model. Two-wheelers can use lanes/paths
/// cars can't, so motorbike distances differ from car distances.
#[derive(Debug, Clone, Copy)]
pub enum RouteProfile {
    Motorcycle,
    Auto,
}

impl RouteProfile {
    fn valhalla_costing(self) -> &'static str {
        match self {
            RouteProfile::Motorcycle => "motorcycle",
            RouteProfile::Auto => "auto",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Engine {
    Valhalla,
    Osrm,
}

#[derive(Debug, Clone)]
pub struct RouteResult {
    pub distance_km: Decimal,
    pub duration_secs: i32,
    pub source: &'static str,
}

pub struct Router {
    url: String,
    engine: Engine,
    road_factor: f64,
    avg_speed_kmh: f64,
    http: reqwest::Client,
}

// ── Valhalla wire types (only the fields we need) ────────────────────────────
#[derive(Serialize)]
struct ValhallaLoc {
    lat: f64,
    lon: f64,
}

#[derive(Serialize)]
struct ValhallaReq<'a> {
    locations: Vec<ValhallaLoc>,
    costing: &'a str,
    directions_options: ValhallaDirOpts,
}

#[derive(Serialize)]
struct ValhallaDirOpts {
    units: &'static str,
}

#[derive(Deserialize)]
struct ValhallaResp {
    trip: ValhallaTrip,
}

#[derive(Deserialize)]
struct ValhallaTrip {
    #[serde(default)]
    status: i32,
    summary: ValhallaSummary,
}

#[derive(Deserialize)]
struct ValhallaSummary {
    length: f64, // km (units=kilometers)
    time: f64,   // seconds
}

// ── OSRM wire types ──────────────────────────────────────────────────────────
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
        let engine = match cfg.routing_engine.to_ascii_lowercase().as_str() {
            "osrm" => Engine::Osrm,
            _ => Engine::Valhalla,
        };
        Router {
            url: cfg.routing_url.trim_end_matches('/').to_string(),
            engine,
            road_factor: cfg.road_factor.to_f64().unwrap_or(1.3),
            avg_speed_kmh: cfg.avg_speed_kmh.to_f64().unwrap_or(22.0),
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(4))
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
                source: "none",
            };
        }
        if !self.url.is_empty() {
            let engine_result = match self.engine {
                Engine::Valhalla => self.valhalla(points, profile).await,
                Engine::Osrm => self.osrm_path(points).await,
            };
            match engine_result {
                Ok(r) => return r,
                Err(e) => {
                    tracing::warn!(error = %e, "routing engine failed; using haversine fallback")
                }
            }
        }
        self.haversine_path(points)
    }

    /// One Valhalla `/route` call for the entire ordered path.
    async fn valhalla(
        &self,
        points: &[LatLng],
        profile: RouteProfile,
    ) -> anyhow::Result<RouteResult> {
        let req = ValhallaReq {
            locations: points
                .iter()
                .map(|p| ValhallaLoc {
                    lat: p.lat,
                    lon: p.lng,
                })
                .collect(),
            costing: profile.valhalla_costing(),
            directions_options: ValhallaDirOpts {
                units: "kilometers",
            },
        };
        let resp: ValhallaResp = self
            .http
            .post(format!("{}/route", self.url))
            .json(&req)
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        if resp.trip.status != 0 {
            anyhow::bail!("valhalla trip status {}", resp.trip.status);
        }
        Ok(RouteResult {
            distance_km: Decimal::from_f64(resp.trip.summary.length)
                .unwrap_or_default()
                .round_dp(3),
            duration_secs: resp.trip.summary.time.round() as i32,
            source: "valhalla",
        })
    }

    /// OSRM per-leg summation (OSRM's `route` service is pairwise here).
    async fn osrm_path(&self, points: &[LatLng]) -> anyhow::Result<RouteResult> {
        let mut distance_km = Decimal::ZERO;
        let mut duration_secs = 0i32;
        for leg in points.windows(2) {
            let r = self.osrm(leg[0], leg[1]).await?;
            distance_km += r.distance_km;
            duration_secs += r.duration_secs;
        }
        Ok(RouteResult {
            distance_km,
            duration_secs,
            source: "osrm",
        })
    }

    async fn osrm(&self, o: LatLng, d: LatLng) -> anyhow::Result<RouteResult> {
        // OSRM expects lng,lat order.
        let url = format!(
            "{}/route/v1/driving/{},{};{},{}?overview=false",
            self.url, o.lng, o.lat, d.lng, d.lat
        );
        let resp: OsrmResponse = self
            .http
            .get(url)
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        let route = resp
            .routes
            .into_iter()
            .next()
            .ok_or_else(|| anyhow::anyhow!("no route"))?;
        let km = Decimal::from_f64(route.distance / 1000.0)
            .unwrap_or_default()
            .round_dp(3);
        Ok(RouteResult {
            distance_km: km,
            duration_secs: route.duration.round() as i32,
            source: "osrm",
        })
    }

    /// Haversine sum over the legs (offline-safe fallback).
    fn haversine_path(&self, points: &[LatLng]) -> RouteResult {
        let mut road = 0.0;
        for leg in points.windows(2) {
            road += haversine_km(leg[0], leg[1]) * self.road_factor;
        }
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
