//! `saarathi-routing` — fare distance/duration only.
//!
//! Wraps a self-hosted **Valhalla** (default) or **OSRM** engine behind a single
//! `POST /v1/route` endpoint. When the upstream engine is unreachable (or
//! unconfigured) it falls back to a haversine estimate so fares keep working on
//! flaky rural connectivity. No POIs, no turn-by-turn, no nearby search.

use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use rust_decimal::prelude::*;
use saarathi_core::routing::{haversine_path, LatLng, RouteProfile, RouteRequest, RouteResult};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::Duration;
use tower_http::{catch_panic::CatchPanicLayer, trace::TraceLayer};

#[derive(Debug, Clone, Copy, PartialEq)]
enum Engine {
    Valhalla,
    Osrm,
}

#[derive(Clone)]
struct AppState {
    inner: Arc<Inner>,
    /// Redis route cache (identical origin/dest pairs recur). `None` = no cache.
    cache: Option<redis::aio::ConnectionManager>,
    cache_ttl_secs: u64,
}

struct Inner {
    url: String,
    engine: Engine,
    road_factor: f64,
    avg_speed_kmh: f64,
    http: reqwest::Client,
}

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key)
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| default.into())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let engine = match env_or("ROUTING_ENGINE", "valhalla")
        .to_ascii_lowercase()
        .as_str()
    {
        "osrm" => Engine::Osrm,
        _ => Engine::Valhalla,
    };
    let inner = Inner {
        url: env_or("ROUTING_URL", "").trim_end_matches('/').to_string(),
        engine,
        road_factor: env_or("ROUTING_ROAD_FACTOR", "1.3").parse().unwrap_or(1.3),
        avg_speed_kmh: env_or("ROUTING_AVG_SPEED_KMH", "22")
            .parse()
            .unwrap_or(22.0),
        http: reqwest::Client::builder()
            .timeout(Duration::from_secs(4))
            .build()
            .expect("http client"),
    };
    let port: u16 = env_or("ROUTING_PORT", "8084").parse()?;

    // Optional Redis cache: real engine results only, keyed by profile+points.
    let cache = match redis::Client::open(env_or("REDIS_URL", "redis://localhost:6379")) {
        Ok(client) => match redis::aio::ConnectionManager::new(client).await {
            Ok(cm) => Some(cm),
            Err(e) => {
                tracing::warn!(error = %e, "route cache unavailable; running without it");
                None
            }
        },
        Err(e) => {
            tracing::warn!(error = %e, "invalid REDIS_URL; running without route cache");
            None
        }
    };
    let cache_ttl_secs: u64 = env_or("ROUTE_CACHE_TTL_SECS", "3600")
        .parse()
        .unwrap_or(3600);

    let state = AppState {
        inner: Arc::new(inner),
        cache,
        cache_ttl_secs,
    };

    let app = Router::new()
        .route("/health", get(health))
        .route("/v1/route", post(route))
        .layer(CatchPanicLayer::new())
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("saarathi-routing listening on http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "service": "saarathi-routing", "status": "ok" }))
}

async fn route(
    axum::extract::State(st): axum::extract::State<AppState>,
    Json(req): Json<RouteRequest>,
) -> Result<Json<RouteResult>, StatusCode> {
    if req.points.len() < 2 {
        return Ok(Json(RouteResult {
            distance_km: Decimal::ZERO,
            duration_secs: 0,
            geometry: Vec::new(),
            source: "none".into(),
        }));
    }
    let profile = RouteProfile::from_wire(&req.profile);
    let inner = &st.inner;

    // Cache lookup (real engine results only — never the offline fallback).
    let key = cache_key(&req.points, profile);
    if let Some(mut cm) = st.cache.clone() {
        let cached: Option<String> = redis::cmd("GET")
            .arg(&key)
            .query_async(&mut cm)
            .await
            .ok()
            .flatten();
        if let Some(mut r) = cached.and_then(|j| serde_json::from_str::<RouteResult>(&j).ok()) {
            r.source = format!("{}+cache", r.source);
            return Ok(Json(r));
        }
    }

    if !inner.url.is_empty() {
        let engine_result = match inner.engine {
            Engine::Valhalla => inner.valhalla(&req.points, profile).await,
            Engine::Osrm => inner.osrm_path(&req.points).await,
        };
        match engine_result {
            Ok(r) => {
                if let Some(mut cm) = st.cache.clone() {
                    if let Ok(json) = serde_json::to_string(&r) {
                        let _ = redis::cmd("SET")
                            .arg(&key)
                            .arg(json)
                            .arg("EX")
                            .arg(st.cache_ttl_secs)
                            .query_async::<()>(&mut cm)
                            .await;
                    }
                }
                return Ok(Json(r));
            }
            Err(e) => {
                tracing::warn!(error = %e, "routing engine failed; using haversine fallback")
            }
        }
    }
    Ok(Json(haversine_path(
        &req.points,
        inner.road_factor,
        inner.avg_speed_kmh,
    )))
}

/// Deterministic cache key: profile + coords rounded to ~1m so identical
/// origin/dest pairs hit the same entry.
fn cache_key(points: &[LatLng], profile: RouteProfile) -> String {
    let mut s = format!("route:v1:{}", profile.as_wire());
    for p in points {
        s.push_str(&format!(":{:.5},{:.5}", p.lat, p.lng));
    }
    s
}

#[cfg(test)]
mod cache_key_tests {
    use super::*;

    #[test]
    fn identical_points_and_profile_produce_the_same_key() {
        let a = [LatLng { lat: 27.7172, lng: 85.3240 }, LatLng { lat: 27.7, lng: 85.3 }];
        let b = [LatLng { lat: 27.7172, lng: 85.3240 }, LatLng { lat: 27.7, lng: 85.3 }];
        assert_eq!(cache_key(&a, RouteProfile::Motorcycle), cache_key(&b, RouteProfile::Motorcycle));
    }

    #[test]
    fn different_profiles_produce_different_keys() {
        let pts = [LatLng { lat: 27.7172, lng: 85.3240 }, LatLng { lat: 27.7, lng: 85.3 }];
        assert_ne!(
            cache_key(&pts, RouteProfile::Motorcycle),
            cache_key(&pts, RouteProfile::Auto)
        );
    }

    #[test]
    fn coordinates_within_a_meter_collapse_to_the_same_key() {
        // Rounded to 5dp (~1.1m at the equator) so near-identical requests
        // (GPS jitter) still hit the same cache entry.
        let a = [LatLng { lat: 27.71720, lng: 85.32400 }];
        let b = [LatLng { lat: 27.717201, lng: 85.324001 }];
        assert_eq!(cache_key(&a, RouteProfile::Motorcycle), cache_key(&b, RouteProfile::Motorcycle));
    }

    #[test]
    fn point_order_changes_the_key() {
        // Origin/dest reversed is a materially different route, not a
        // cache-equivalent request.
        let a = [LatLng { lat: 27.7172, lng: 85.3240 }, LatLng { lat: 27.7, lng: 85.3 }];
        let b = [LatLng { lat: 27.7, lng: 85.3 }, LatLng { lat: 27.7172, lng: 85.3240 }];
        assert_ne!(cache_key(&a, RouteProfile::Motorcycle), cache_key(&b, RouteProfile::Motorcycle));
    }
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
    #[serde(default)]
    legs: Vec<ValhallaLeg>,
}

#[derive(Deserialize)]
struct ValhallaLeg {
    /// Encoded polyline (Valhalla uses precision 1e6) of this leg's shape.
    #[serde(default)]
    shape: String,
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
    #[serde(default)]
    geometry: OsrmGeometry,
}

#[derive(Deserialize, Default)]
struct OsrmGeometry {
    /// GeoJSON LineString coordinates as [lng, lat] pairs.
    #[serde(default)]
    coordinates: Vec<[f64; 2]>,
}

/// Decode an encoded polyline (Google/Valhalla algorithm). `precision` is the
/// coordinate scale (1e5 for OSRM `polyline`, 1e6 for Valhalla).
fn decode_polyline(encoded: &str, precision: f64) -> Vec<LatLng> {
    let mut lat = 0i64;
    let mut lng = 0i64;
    let mut out = Vec::new();
    let bytes = encoded.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let mut shift = 0u32;
        let mut result = 0i64;
        loop {
            if i >= bytes.len() {
                return out;
            }
            let b = bytes[i] as i64 - 63;
            i += 1;
            result |= (b & 0x1f) << shift;
            shift += 5;
            if b < 0x20 {
                break;
            }
        }
        lat += if result & 1 != 0 {
            !(result >> 1)
        } else {
            result >> 1
        };
        shift = 0;
        result = 0;
        loop {
            if i >= bytes.len() {
                return out;
            }
            let b = bytes[i] as i64 - 63;
            i += 1;
            result |= (b & 0x1f) << shift;
            shift += 5;
            if b < 0x20 {
                break;
            }
        }
        lng += if result & 1 != 0 {
            !(result >> 1)
        } else {
            result >> 1
        };
        out.push(LatLng {
            lat: lat as f64 / precision,
            lng: lng as f64 / precision,
        });
    }
    out
}

#[cfg(test)]
mod polyline_tests {
    use super::*;

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-4
    }

    #[test]
    fn decodes_googles_canonical_example_at_1e5_precision() {
        // https://developers.google.com/maps/documentation/utilities/polylinealgorithm
        let points = decode_polyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@", 1e5);
        let expected = [(38.5, -120.2), (40.7, -120.95), (43.252, -126.453)];
        assert_eq!(points.len(), expected.len());
        for (got, (lat, lng)) in points.iter().zip(expected) {
            assert!(close(got.lat, lat), "lat: got {} want {lat}", got.lat);
            assert!(close(got.lng, lng), "lng: got {} want {lng}", got.lng);
        }
    }

    #[test]
    fn empty_string_decodes_to_no_points() {
        assert!(decode_polyline("", 1e5).is_empty());
    }

    #[test]
    fn truncated_input_returns_whatever_decoded_so_far_not_a_panic() {
        // A cut-off byte stream (e.g. a truncated Valhalla response) must
        // degrade gracefully, never index-panic mid-decode.
        let full = "_p~iF~ps|U_ulLnnqC_mqNvxq`@";
        let points = decode_polyline(&full[..full.len() - 1], 1e5);
        assert!(points.len() <= 3);
    }

    #[test]
    fn precision_1e6_scales_differently_than_1e5() {
        // Same raw varint stream, different scale factor -> different decoded
        // magnitude — this is the actual Valhalla-vs-OSRM distinction the
        // function exists to handle.
        let encoded = "_p~iF~ps|U";
        let p5 = decode_polyline(encoded, 1e5);
        let p6 = decode_polyline(encoded, 1e6);
        assert_eq!(p5.len(), 1);
        assert_eq!(p6.len(), 1);
        assert!((p5[0].lat - p6[0].lat * 10.0).abs() < 1e-3);
    }
}

impl Inner {
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
            costing: profile.as_wire(),
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
        // Valhalla returns one encoded polyline per leg (precision 1e6); stitch
        // them into a single ordered path for the map.
        let mut geometry = Vec::new();
        for leg in &resp.trip.legs {
            if !leg.shape.is_empty() {
                geometry.extend(decode_polyline(&leg.shape, 1e6));
            }
        }
        Ok(RouteResult {
            distance_km: Decimal::from_f64(resp.trip.summary.length)
                .unwrap_or_default()
                .round_dp(3),
            duration_secs: resp.trip.summary.time.round() as i32,
            geometry,
            source: "valhalla".into(),
        })
    }

    /// OSRM per-leg summation (OSRM's `route` service is pairwise here).
    async fn osrm_path(&self, points: &[LatLng]) -> anyhow::Result<RouteResult> {
        let mut distance_km = Decimal::ZERO;
        let mut duration_secs = 0i32;
        let mut geometry = Vec::new();
        for leg in points.windows(2) {
            let r = self.osrm(leg[0], leg[1]).await?;
            distance_km += r.distance_km;
            duration_secs += r.duration_secs;
            geometry.extend(r.geometry);
        }
        Ok(RouteResult {
            distance_km,
            duration_secs,
            geometry,
            source: "osrm".into(),
        })
    }

    async fn osrm(&self, o: LatLng, d: LatLng) -> anyhow::Result<RouteResult> {
        // OSRM expects lng,lat order. Ask for the full route geometry as GeoJSON.
        let url = format!(
            "{}/route/v1/driving/{},{};{},{}?overview=full&geometries=geojson",
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
        let geometry = route
            .geometry
            .coordinates
            .into_iter()
            .map(|c| LatLng {
                lat: c[1],
                lng: c[0],
            })
            .collect();
        Ok(RouteResult {
            distance_km: km,
            duration_secs: route.duration.round() as i32,
            geometry,
            source: "osrm".into(),
        })
    }
}
