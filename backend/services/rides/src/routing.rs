//! Thin client for **saarathi-routing**. `rides` no longer speaks Valhalla/OSRM
//! directly — it asks the routing service to measure a path, and on any failure
//! (service down, timeout) falls back to a local haversine estimate so fares
//! keep working offline. Shared wire types live in `saarathi_core::routing`.

pub use saarathi_core::routing::{LatLng, RouteProfile, RouteResult};

use crate::config::Config;
use rust_decimal::prelude::*;
use saarathi_core::routing::{haversine_path, RouteRequest};
use std::time::Duration;

pub struct Router {
    /// Base URL of the routing service, e.g. http://localhost:8084. Empty = local
    /// haversine only.
    service_url: String,
    road_factor: f64,
    avg_speed_kmh: f64,
    http: reqwest::Client,
}

impl Router {
    pub fn new(cfg: &Config) -> Self {
        Router {
            service_url: cfg.routing_service_url.trim_end_matches('/').to_string(),
            road_factor: cfg.road_factor.to_f64().unwrap_or(1.3),
            avg_speed_kmh: cfg.avg_speed_kmh.to_f64().unwrap_or(22.0),
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(5))
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
