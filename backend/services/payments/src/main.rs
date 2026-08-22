//! `saarathi-payments` — payment operations (top-ups, payouts, PSP callbacks).
//!
//! Owns the standalone money operations that run as their own transactions with
//! no trip involved. Trip-completion **settlement** (ledger + wallet deltas)
//! deliberately stays in `rides` inside the atomic trip transaction — see
//! docs/research/15-service-decomposition.md. Shares the Postgres DB with rides;
//! `rides` owns the money-table schema, this service reads/writes it.

mod auth;
mod disputes;
mod error;
mod notify;
mod payout_accounts;
mod routes;
mod state;
mod trip_payments;
mod wallet;

use axum::{routing::get, Json, Router};
use rust_decimal::Decimal;
use sqlx::postgres::PgPoolOptions;
use state::AppState;
use std::sync::Arc;
use std::time::Duration;
use tower_http::{catch_panic::CatchPanicLayer, trace::TraceLayer};

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
    let nats_url = env_or("NATS_URL", "nats://localhost:4222");

    let db = PgPoolOptions::new()
        .max_connections(10)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&database_url)
        .await?;

    // NATS bus for top-up/payout notifications (non-fatal: money moves fine
    // if the bus is down, the user just doesn't get told).
    let nats = match async_nats::connect(&nats_url).await {
        Ok(c) => Some(c),
        Err(e) => {
            tracing::warn!(error = %e, "NATS unavailable; payment notifications will be skipped");
            None
        }
    };

    let state = AppState {
        db,
        jwt_secret: Arc::new(jwt_secret),
        payments: saarathi_core::payments::provider_from_env(),
        tds_rate,
        nats,
    };

    let app = Router::new()
        .route("/health", get(health))
        .merge(routes::routes())
        .merge(payout_accounts::routes())
        .merge(disputes::routes())
        .merge(trip_payments::routes())
        .layer(CatchPanicLayer::new())
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
