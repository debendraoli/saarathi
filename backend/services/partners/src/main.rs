//! `saarathi-partners` — the fleet/partner domain, consolidated.
//!
//! Owns partner governance (staff), the partner-staff portal (members, fleet
//! drivers, corporate riders), fleet money (wallet/topup/payouts), the
//! revenue-share ledger view, fleet analytics, and partner-funded campaigns.
//! The trip-settlement partner money (revenue-share accrual, corporate charge,
//! partner-funded bonus) stays in `rides` inside the trip transaction — see
//! docs/research/16-partner-service.md. Shares the Postgres DB (auth owns the
//! identity + partner-table DDL; this service reads/writes it).

mod audit;
mod auth;
mod error;
mod rbac;
mod routes;
mod state;

use axum::{routing::get, Json, Router};
use rust_decimal::Decimal;
use saarathi_core::payments::MockProvider;
use sqlx::postgres::PgPoolOptions;
use state::AppState;
use std::sync::Arc;
use std::time::Duration;
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
    let port: u16 = env_or("PARTNERS_PORT", "8087").parse()?;
    let tds_rate: Decimal = env_or("PAYOUT_TDS_RATE", "0.015").parse()?;

    let db = PgPoolOptions::new()
        .max_connections(10)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&database_url)
        .await?;

    let state = AppState {
        db,
        jwt_secret: Arc::new(jwt_secret),
        payments: Arc::new(MockProvider),
        tds_rate,
    };

    let app = Router::new()
        .route("/health", get(health))
        .merge(routes::admin::routes())
        .merge(routes::portal::routes())
        .merge(routes::fleet::routes())
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("saarathi-partners listening on http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "service": "saarathi-partners", "status": "ok" }))
}
