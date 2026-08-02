//! `saarathi-payments` — payment operations (top-ups, payouts, PSP callbacks).
//!
//! Owns the standalone money operations that run as their own transactions with
//! no trip involved. Trip-completion **settlement** (ledger + wallet deltas)
//! deliberately stays in `rides` inside the atomic trip transaction — see
//! docs/research/15-service-decomposition.md. Shares the Postgres DB with rides;
//! `rides` owns the money-table schema, this service reads/writes it.

mod auth;
mod error;
mod routes;
mod state;
mod wallet;

use axum::http::{HeaderName, Method};
use axum::{routing::get, Json, Router};
use rust_decimal::Decimal;
use saarathi_core::payments::MockProvider;
use sqlx::postgres::PgPoolOptions;
use state::AppState;
use std::sync::Arc;
use std::time::Duration;
use tower_http::cors::{AllowOrigin, CorsLayer};
use tower_http::trace::TraceLayer;

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

    let database_url = std::env::var("DATABASE_URL")?;
    let jwt_secret = std::env::var("JWT_SECRET")?;
    let port: u16 = env_or("PAYMENTS_PORT", "8085").parse()?;
    let tds_rate: Decimal = env_or("PAYOUT_TDS_RATE", "0.015").parse()?;
    let origins: Vec<_> = env_or("CORS_ORIGINS", "http://localhost:3000")
        .split(',')
        .filter_map(|o| o.trim().parse().ok())
        .collect();

    let db = PgPoolOptions::new()
        .max_connections(10)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&database_url)
        .await?;

    let cors = CorsLayer::new()
        .allow_origin(AllowOrigin::list(origins))
        .allow_methods([Method::GET, Method::POST, Method::OPTIONS])
        .allow_headers([
            HeaderName::from_static("authorization"),
            HeaderName::from_static("content-type"),
        ]);

    let state = AppState {
        db,
        jwt_secret: Arc::new(jwt_secret),
        payments: Arc::new(MockProvider),
        tds_rate,
    };

    let app = Router::new()
        .route("/health", get(health))
        .merge(routes::routes())
        .layer(cors)
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("saarathi-payments listening on http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "service": "saarathi-payments", "status": "ok" }))
}
