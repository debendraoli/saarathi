//! `saarathi-merchant` — the merchant/marketplace domain (food + grocery):
//! merchants, menus, customer orders, and delivery geofences. Extracted out
//! of `saarathi-rides` (Phase 2 brief: "decouple `merchant` domain into its
//! own crate/service with a clear API boundary"). Never touches ride
//! dispatch/settlement directly — when an order goes `ready`, it calls
//! rides' `/v1/internal/delivery-trips` (not exposed via the gateway) to
//! spawn the courier leg, instead of reaching into rides' internals.

mod auth;
mod config;
mod error;
mod routes;
mod state;

use axum::{routing::get, Json, Router};
use config::Config;
use rust_decimal::prelude::*;
use saarathi_core::routing::RoutingClient;
use sqlx::postgres::PgPoolOptions;
use state::AppState;
use std::sync::Arc;
use std::time::Duration;
use tower_http::{catch_panic::CatchPanicLayer, trace::TraceLayer};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let config = Config::from_env()?;

    let db = PgPoolOptions::new()
        .max_connections(10)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&config.database_url)
        .await?;
    sqlx::raw_sql(include_str!("schema.sql")).execute(&db).await?;

    let redis_client = redis::Client::open(config.redis_url.clone())?;
    let redis = redis::aio::ConnectionManager::new(redis_client).await?;

    let router = Arc::new(RoutingClient::new(
        config.routing_service_url.clone(),
        config.road_factor.to_f64().unwrap_or(1.3),
        config.avg_speed_kmh.to_f64().unwrap_or(22.0),
    ));
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()?;

    let port = config.port;
    let state = AppState {
        db,
        config: Arc::new(config),
        redis,
        router,
        http,
    };

    let app = Router::new()
        .route("/health", get(health))
        .merge(routes::router())
        .layer(CatchPanicLayer::new())
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("saarathi-merchant listening on http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "service": "saarathi-merchant", "status": "ok" }))
}
