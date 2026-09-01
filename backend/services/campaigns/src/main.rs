//! `saarathi-campaigns` — campaign (discount/bonus) management.
//!
//! Owns staff campaign CRUD + rider preview. Rides still *evaluates* campaigns
//! (discount at estimate, bonus at trip completion) by reading the same
//! `campaigns` table — see docs/research/15-service-decomposition.md. Shares the
//! Postgres DB; `rides` owns the campaign schema.

mod auth;
mod error;
mod routes;
mod state;

use axum::Router;
use saarathi_core::bootstrap::{connect_pg, env_or, health_router, init_tracing};
use state::AppState;
use std::sync::Arc;
use tower_http::{catch_panic::CatchPanicLayer, trace::TraceLayer};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    init_tracing();

    let database_url = std::env::var("DATABASE_URL")?;
    let jwt_secret = std::env::var("JWT_SECRET")?;
    let port: u16 = env_or("CAMPAIGNS_PORT", "8086").parse()?;

    let db = connect_pg(&database_url).await?;

    let state = AppState {
        db,
        jwt_secret: Arc::new(jwt_secret),
    };

    let app = Router::new()
        .merge(health_router("saarathi-campaigns"))
        .merge(routes::routes())
        .layer(CatchPanicLayer::new())
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("saarathi-campaigns listening on http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}
