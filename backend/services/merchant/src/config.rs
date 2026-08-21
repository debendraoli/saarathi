//! Runtime configuration for saarathi-merchant.

use anyhow::Context;
use rust_decimal::Decimal;

#[derive(Debug, Clone)]
pub struct Config {
    pub database_url: String,
    pub port: u16,
    pub jwt_secret: String,
    pub redis_url: String,
    /// Base URL of the saarathi-routing service. Empty = local haversine fallback.
    pub routing_service_url: String,
    pub road_factor: Decimal,
    pub avg_speed_kmh: Decimal,
    /// Base URL of saarathi-rides, for the internal delivery-trip API this
    /// service calls through instead of touching dispatch/settlement directly
    /// (see rides' `routes::internal`).
    pub rides_service_url: String,
    /// Shared secret sent as `X-Internal-Secret` on calls to rides' internal
    /// API. Must match rides' own `INTERNAL_SERVICE_SECRET`.
    pub internal_service_secret: String,
    pub delivery_base_fare: Decimal,
    pub delivery_per_km: Decimal,
}

impl Config {
    pub fn from_env() -> anyhow::Result<Self> {
        Ok(Config {
            database_url: req("DATABASE_URL")?,
            port: opt("MERCHANT_PORT")
                .unwrap_or_else(|| "8088".into())
                .parse()
                .context("MERCHANT_PORT")?,
            jwt_secret: req("JWT_SECRET")?,
            redis_url: opt("REDIS_URL").unwrap_or_else(|| "redis://localhost:6379".into()),
            routing_service_url: opt("ROUTING_SERVICE_URL").unwrap_or_default(),
            road_factor: dec_env("ROUTING_ROAD_FACTOR", "1.3"),
            avg_speed_kmh: dec_env("ROUTING_AVG_SPEED_KMH", "22"),
            rides_service_url: opt("RIDES_SERVICE_URL")
                .unwrap_or_else(|| "http://localhost:8082".into()),
            internal_service_secret: opt("INTERNAL_SERVICE_SECRET").unwrap_or_default(),
            delivery_base_fare: dec_env("DELIVERY_BASE_FARE", "30"),
            delivery_per_km: dec_env("DELIVERY_PER_KM", "15"),
        })
    }
}

fn req(key: &str) -> anyhow::Result<String> {
    std::env::var(key).with_context(|| format!("missing required env var {key}"))
}

fn opt(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.is_empty())
}

fn dec_env(key: &str, default: &str) -> Decimal {
    opt(key)
        .and_then(|v| v.parse().ok())
        .unwrap_or_else(|| default.parse().expect("valid default decimal"))
}
