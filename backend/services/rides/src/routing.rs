//! Thin per-service wiring for the shared routing-service client — see
//! `saarathi_core::routing::RoutingClient`, the single implementation now
//! shared with `saarathi-merchant`.

pub use saarathi_core::routing::{LatLng, RouteProfile, RouteResult};

use crate::config::Config;
use rust_decimal::prelude::*;
use saarathi_core::routing::RoutingClient;

pub struct Router(RoutingClient);

impl Router {
    pub fn new(cfg: &Config) -> Self {
        Router(RoutingClient::new(
            cfg.routing_service_url.clone(),
            cfg.road_factor.to_f64().unwrap_or(1.3),
            cfg.avg_speed_kmh.to_f64().unwrap_or(22.0),
        ))
    }

    pub async fn route_path(&self, points: &[LatLng], profile: RouteProfile) -> RouteResult {
        self.0.route_path(points, profile).await
    }
}
