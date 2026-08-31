//! `saarathi-rides` — trips, fare estimation, campaigns, and realtime comms.
//!
//! Owns the ride lifecycle, the routing-based fare estimate (legal caps enforced
//! by `saarathi-core`), promo campaigns, and a trip-scoped WebSocket that carries
//! near-realtime status/location, chat, and WebRTC signaling. See ../../../AGENTS.md.
//!
//! Thin entry point — the actual wiring lives in `lib.rs` so integration
//! tests can reuse it.

use saarathi_rides::config::Config;
use saarathi_rides::{bootstrap, dispatch, routes, user_status_sub};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let config = Config::from_env()?;
    let port = config.port;
    let state = bootstrap(config).await?;

    tokio::spawn(dispatch::run_dispatcher(state.clone()));
    tokio::spawn(user_status_sub::run(state.clone()));

    let app = routes::router(state);
    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("saarathi-rides listening on http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}
