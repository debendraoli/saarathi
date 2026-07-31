//! `saarathi-rides` — trips, fare estimation, campaigns, and realtime comms.
//!
//! Owns the ride lifecycle, the routing-based fare estimate (legal caps enforced
//! by `saarathi-core`), promo campaigns, and a trip-scoped WebSocket that carries
//! near-realtime status/location, chat, and WebRTC signaling. See ../../../AGENTS.md.

mod auth;
mod config;
mod db;
mod error;
mod hub;
mod ledger;
mod models;
mod pricing;
mod routes;
mod routing;
mod state;
mod ws;

use config::Config;
use hub::Hub;
use routing::Router;
use state::AppState;
use std::sync::Arc;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let config = Config::from_env()?;
    let pool = db::connect(&config.database_url).await?;
    db::init_schema(&pool).await?;

    let router = Arc::new(Router::new(&config));
    let port = config.port;
    let state = AppState {
        db: pool,
        config: Arc::new(config),
        router,
        hub: Hub::new(),
    };

    let app = routes::router(state);
    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("saarathi-rides listening on http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}
