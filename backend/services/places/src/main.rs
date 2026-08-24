//! `saarathi-places` — community map contributions: any signed-in user can
//! submit a place (organisation, building, landmark, construction, closed
//! road, sign) with a camera-proof photo, staff review it from the
//! dashboard, and an approved contributor earns points redeemable for wallet
//! credit plus milestone badges. New microservice (Phase brief: "Map/Places
//! contribution") rather than folded into `rides` — a distinct domain
//! (community content + gamification) with its own review queue, same
//! extraction rationale as `merchant`.

mod auth;
mod config;
mod error;
mod notify;
mod pelias_index;
mod points;
mod routes;
mod state;
mod store;

use axum::{routing::get, Json, Router};
use config::Config;
use sqlx::postgres::PgPoolOptions;
use state::AppState;
use std::sync::Arc;
use std::time::Duration;
use store::LocalDocumentStore;
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
    store::ensure_dir(&config.places_storage_dir)?;

    let db = PgPoolOptions::new()
        .max_connections(10)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&config.database_url)
        .await?;
    sqlx::raw_sql(include_str!("schema.sql")).execute(&db).await?;

    // NATS bus for review notifications (non-fatal: reviews work fine if the
    // bus is down, the contributor just doesn't get told).
    let nats = match async_nats::connect(&config.nats_url).await {
        Ok(c) => Some(c),
        Err(e) => {
            tracing::warn!(error = %e, "NATS unavailable; contribution notifications will be skipped");
            None
        }
    };

    let docs = Arc::new(LocalDocumentStore::new(&config.places_storage_dir));
    let port = config.port;
    let state = AppState {
        db,
        config: Arc::new(config),
        docs,
        nats,
    };

    let app = Router::new()
        .route("/health", get(health))
        .merge(routes::router())
        .layer(CatchPanicLayer::new())
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("saarathi-places listening on http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({ "service": "saarathi-places", "status": "ok" }))
}
