//! `saarathi-routing` — fare distance/duration only.
//!
//! Wraps a self-hosted **Valhalla** (default) or **OSRM** engine behind a single
//! `POST /v1/route` endpoint. When the upstream engine is unreachable (or
//! unconfigured) it falls back to a haversine estimate so fares keep working on
//! flaky rural connectivity. No POIs, no turn-by-turn, no nearby search.

use axum::http::{HeaderName, Method, StatusCode};
use axum::routing::{get, post};
use axum::{Json, Router};
use rust_decimal::prelude::*;
use saarathi_core::routing::{haversine_path, LatLng, RouteProfile, RouteRequest, RouteResult};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::Duration;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;

#[derive(Debug, Clone, Copy, PartialEq)]
enum Engine {
    Valhalla,
    Osrm,
}

#[derive(Clone)]
struct AppState {
    inner: Arc<Inner>,
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
    let state = AppState {
        inner: Arc::new(inner),
    };

    // Routing has no user data and is called service-to-service; allow any origin.
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods([Method::GET, Method::POST, Method::OPTIONS])
        .allow_headers([HeaderName::from_static("content-type")]);

    let app = Router::new()
        .route("/health", get(health))
        .route("/v1/route", post(route))
        .layer(cors)
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
            source: "none".into(),
        }));
    }
    let profile = RouteProfile::from_wire(&req.profile);
    let inner = &st.inner;
    if !inner.url.is_empty() {
        let engine_result = match inner.engine {
            Engine::Valhalla => inner.valhalla(&req.points, profile).await,
            Engine::Osrm => inner.osrm_path(&req.points).await,
        };
        match engine_result {
            Ok(r) => return Ok(Json(r)),
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
        Ok(RouteResult {
            distance_km: Decimal::from_f64(resp.trip.summary.length)
                .unwrap_or_default()
                .round_dp(3),
            duration_secs: resp.trip.summary.time.round() as i32,
            source: "valhalla".into(),
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
            source: "osrm".into(),
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
            source: "osrm".into(),
        })
    }
}
