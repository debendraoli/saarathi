//! Library surface for `saarathi-rides`, split out from `main.rs` so
//! integration tests (`tests/`) can build a real [`state::AppState`] and the
//! real [`routes::router`] without going through the binary's `main()`.

pub mod auth;
pub mod bonus;
pub mod config;
pub mod db;
pub mod dispatch;
pub mod driver_ws;
pub mod error;
pub mod flags;
pub mod ledger;
pub mod models;
pub mod notify;
pub mod partner_ledger;
pub mod payments;
pub mod pricing;
pub mod routes;
pub mod routing;
pub mod rules;
pub mod settle;
pub mod state;
pub mod surge;
pub mod user_status_sub;
pub mod ws;

use config::Config;
use routing::Router;
use saarathi_core::hub::Hub;
use state::AppState;
use std::sync::Arc;

/// Assemble a real [`AppState`] from config — the exact wiring `main()` uses,
/// shared here so integration tests build the identical thing they're testing
/// rather than a hand-rolled approximation of it.
pub async fn bootstrap(config: Config) -> anyhow::Result<AppState> {
    let pool = db::connect(&config.database_url).await?;
    db::init_schema(&pool).await?;
    db::migrate_off_subscriptions(&pool).await?;

    let redis_client = redis::Client::open(config.redis_url.clone())?;
    let redis = redis::aio::ConnectionManager::new(redis_client).await?;

    // NATS bus for notifications (non-fatal: trips run fine if the bus is down).
    let nats = match async_nats::connect(&config.nats_url).await {
        Ok(c) => Some(c),
        Err(e) => {
            tracing::warn!(error = %e, "NATS unavailable; notifications will be skipped");
            None
        }
    };

    let router = Arc::new(Router::new(&config));
    Ok(AppState {
        db: pool,
        config: Arc::new(config),
        router,
        hub: Hub::new(nats.clone()),
        redis,
        payments: saarathi_core::payments::provider_from_env(),
        nats,
    })
}
