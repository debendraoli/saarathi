//! Runtime configuration for saarathi-rides.

use anyhow::Context;
use rust_decimal::Decimal;

#[derive(Debug, Clone)]
pub struct Config {
    pub database_url: String,
    pub port: u16,
    pub jwt_secret: String,
    /// Shared secret required on `/v1/internal/*` (service-to-service only —
    /// not registered in the gateway). Empty = unauthenticated (logged loudly
    /// at call time), for local dev without the merchant service running.
    pub internal_service_secret: String,
    /// Base URL of the saarathi-routing service, e.g. http://localhost:8084.
    /// Empty = skip the service and use the local haversine fallback.
    pub routing_service_url: String,
    /// Base URL of the saarathi-merchant service, e.g. http://merchant:8088 —
    /// used only to call back into it (`/v1/internal/orders/{id}/redispatch`)
    /// when a delivery trip it created gets cancelled during the arrival
    /// phase. Empty = skip the call (logged); the order is still reverted
    /// locally either way, just without an automatic re-dispatch attempt.
    pub merchant_service_url: String,
    /// Multiplier applied to straight-line distance when falling back to
    /// haversine (approximates real road distance in a town like Ghorahi).
    pub road_factor: Decimal,
    /// Average speed (km/h) used to estimate duration in the haversine fallback.
    pub avg_speed_kmh: Decimal,
    /// Admin-configured per-km rates (clamped to the legal caps by the engine).
    pub two_wheeler_per_km: Decimal,
    pub three_wheeler_per_km: Decimal,
    pub four_wheeler_per_km: Decimal,
    pub commission_rate: Decimal,
    /// Redis connection for the driver geo-index + dispatch.
    pub redis_url: String,
    /// NATS bus URL for inter-service events (notifications).
    pub nats_url: String,
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
    /// How long a ride request searches before giving up as "no driver
    /// found" — also the bid-mode offer visibility window and the
    /// background dispatcher's retry horizon (see dispatch::SEARCH_TIMEOUT).
    pub search_timeout_mins: i64,
    /// Lowest fraction of the algorithmic fare a rider may bargain down to.
    pub bargain_floor_ratio: Decimal,
    /// How long a single driver bid stays live before it drops off the
    /// rider's list on its own (the bidding round itself has no deadline —
    /// only individual bids expire).
    pub bid_ttl_secs: i64,
    /// A driver's counter may not exceed the rider's ask by more than this
    /// multiple (also capped by the legal ceiling, whichever is lower).
    pub bid_counter_max_ratio: Decimal,
    /// VAT rate applied to the platform's commission (reporting / liability).
    pub vat_rate: Decimal,
    /// Parcel delivery pricing (config-driven; not bound by the ride per-km caps).
    pub delivery_base_fare: Decimal,
    pub delivery_per_km: Decimal,
    pub delivery_tier_small: Decimal,
    pub delivery_tier_medium: Decimal,
    pub delivery_fragile_surcharge: Decimal,
    /// WebRTC ICE: self-hosted Coturn. When `turn_secret` is set, `/v1/rtc/ice`
    /// mints short-lived TURN credentials (Coturn `use-auth-secret` REST scheme).
    pub turn_urls: Vec<String>,
    pub turn_stun_url: String,
    pub turn_secret: String,
    pub turn_ttl_secs: i64,
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
            internal_service_secret: opt("INTERNAL_SERVICE_SECRET").unwrap_or_default(),
            routing_service_url: opt("ROUTING_SERVICE_URL").unwrap_or_default(),
            merchant_service_url: opt("MERCHANT_SERVICE_URL").unwrap_or_default(),
            road_factor: dec_env("ROUTING_ROAD_FACTOR", "1.3"),
            avg_speed_kmh: dec_env("ROUTING_AVG_SPEED_KMH", "22"),
            two_wheeler_per_km: dec_env("FARE_TWO_WHEELER_PER_KM", "20"),
            three_wheeler_per_km: dec_env("FARE_THREE_WHEELER_PER_KM", "35"),
            four_wheeler_per_km: dec_env("FARE_FOUR_WHEELER_PER_KM", "45"),
            commission_rate: dec_env("FARE_COMMISSION_RATE", "0.10"),
            redis_url: opt("REDIS_URL").unwrap_or_else(|| "redis://localhost:6379".into()),
            nats_url: opt("NATS_URL").unwrap_or_else(|| "nats://localhost:4222".into()),
            offer_ttl_secs: int_env("DISPATCH_OFFER_TTL_SECS", 15),
            dispatch_radius_km: float_env("DISPATCH_RADIUS_KM", 2.0),
            dispatch_max_radius_km: float_env("DISPATCH_MAX_RADIUS_KM", 8.0),
            dispatch_broadcast_threshold: int_env("DISPATCH_BROADCAST_THRESHOLD", 3) as usize,
            presence_ttl_secs: int_env("DISPATCH_PRESENCE_TTL_SECS", 60),
            search_timeout_mins: int_env("DISPATCH_SEARCH_TIMEOUT_MINS", 5),
            bargain_floor_ratio: dec_env("BARGAIN_FLOOR_RATIO", "0.5"),
            bid_ttl_secs: int_env("BID_TTL_SECS", 60),
            bid_counter_max_ratio: dec_env("BID_COUNTER_MAX_RATIO", "2.0"),
            vat_rate: dec_env("VAT_RATE", "0.13"),
            delivery_base_fare: dec_env("DELIVERY_BASE_FARE", "30"),
            delivery_per_km: dec_env("DELIVERY_PER_KM", "15"),
            delivery_tier_small: dec_env("DELIVERY_TIER_SMALL_SURCHARGE", "10"),
            delivery_tier_medium: dec_env("DELIVERY_TIER_MEDIUM_SURCHARGE", "25"),
            delivery_fragile_surcharge: dec_env("DELIVERY_FRAGILE_SURCHARGE", "20"),
            turn_urls: opt("TURN_URLS")
                .map(|s| {
                    s.split(',')
                        .map(|x| x.trim().to_string())
                        .filter(|x| !x.is_empty())
                        .collect()
                })
                .unwrap_or_default(),
            turn_stun_url: opt("TURN_STUN_URL")
                .unwrap_or_else(|| "stun:stun.l.google.com:19302".into()),
            turn_secret: opt("TURN_SECRET").unwrap_or_default(),
            turn_ttl_secs: int_env("TURN_TTL_SECS", 86_400),
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
