//! Runtime configuration for saarathi-rides.

use anyhow::Context;
use rust_decimal::Decimal;

#[derive(Debug, Clone)]
pub struct Config {
    pub database_url: String,
    pub port: u16,
    pub jwt_secret: String,
    pub cors_origins: Vec<String>,
    /// OSRM/Valhalla base URL, e.g. http://localhost:5000. Empty = haversine only.
    pub routing_url: String,
    /// Multiplier applied to straight-line distance when falling back to
    /// haversine (approximates real road distance in a town like Ghorahi).
    pub road_factor: Decimal,
    /// Average speed (km/h) used to estimate duration in the haversine fallback.
    pub avg_speed_kmh: Decimal,
    /// Admin-configured per-km rates (clamped to the legal caps by the engine).
    pub two_wheeler_per_km: Decimal,
    pub four_wheeler_per_km: Decimal,
    pub commission_rate: Decimal,
    /// Redis connection for the driver geo-index + dispatch.
    pub redis_url: String,
    /// How long a driver has to respond to a job offer before it moves on.
    pub offer_ttl_secs: i64,
    /// Dispatch search radius (km); expands up to the max if no driver responds.
    pub dispatch_radius_km: f64,
    pub dispatch_max_radius_km: f64,
    /// When the pool of eligible drivers is at or below this size, broadcast the
    /// offer to all of them at once (blast radius) instead of one-at-a-time.
    pub dispatch_broadcast_threshold: usize,
    /// How stale a driver heartbeat may be before we treat them as offline (secs).
    pub presence_ttl_secs: i64,
    /// Lowest fraction of the algorithmic fare a rider may bargain down to.
    pub bargain_floor_ratio: Decimal,
    /// Weekly driver subscription pass (unlimited rides, keep 100% of fares).
    pub subscription_weekly_price: Decimal,
    pub subscription_weekly_days: i64,
}

impl Config {
    pub fn from_env() -> anyhow::Result<Self> {
        Ok(Config {
            database_url: req("DATABASE_URL")?,
            port: opt("RIDES_PORT")
                .unwrap_or_else(|| "8082".into())
                .parse()
                .context("RIDES_PORT")?,
            jwt_secret: req("JWT_SECRET")?,
            cors_origins: opt("CORS_ORIGINS")
                .map(|v| {
                    v.split(',')
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .collect()
                })
                .unwrap_or_else(|| vec!["http://localhost:3000".into()]),
            routing_url: opt("ROUTING_URL").unwrap_or_default(),
            road_factor: dec_env("ROUTING_ROAD_FACTOR", "1.3"),
            avg_speed_kmh: dec_env("ROUTING_AVG_SPEED_KMH", "22"),
            two_wheeler_per_km: dec_env("FARE_TWO_WHEELER_PER_KM", "20"),
            four_wheeler_per_km: dec_env("FARE_FOUR_WHEELER_PER_KM", "45"),
            commission_rate: dec_env("FARE_COMMISSION_RATE", "0.10"),
            redis_url: opt("REDIS_URL").unwrap_or_else(|| "redis://localhost:6379".into()),
            offer_ttl_secs: int_env("DISPATCH_OFFER_TTL_SECS", 15),
            dispatch_radius_km: float_env("DISPATCH_RADIUS_KM", 2.0),
            dispatch_max_radius_km: float_env("DISPATCH_MAX_RADIUS_KM", 8.0),
            dispatch_broadcast_threshold: int_env("DISPATCH_BROADCAST_THRESHOLD", 3) as usize,
            presence_ttl_secs: int_env("DISPATCH_PRESENCE_TTL_SECS", 60),
            bargain_floor_ratio: dec_env("BARGAIN_FLOOR_RATIO", "0.5"),
            subscription_weekly_price: dec_env("SUBSCRIPTION_WEEKLY_PRICE", "500"),
            subscription_weekly_days: int_env("SUBSCRIPTION_WEEKLY_DAYS", 7),
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

fn int_env(key: &str, default: i64) -> i64 {
    opt(key).and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn float_env(key: &str, default: f64) -> f64 {
    opt(key).and_then(|v| v.parse().ok()).unwrap_or(default)
}
