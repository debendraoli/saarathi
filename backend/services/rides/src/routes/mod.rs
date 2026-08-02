//! Router assembly + CORS.

pub mod analytics;
pub mod delivery;
pub mod dispatch;
pub mod feedback;
pub mod flags;
pub mod insights;
pub mod ledger;
pub mod metrics;
pub mod plans;
pub mod rides;
pub mod safety;
pub mod subscription;
pub mod surge;
pub mod tracking;

use crate::state::AppState;
use crate::ws;
use axum::{routing::get, Json, Router};
use serde_json::json;
use tower_http::trace::TraceLayer;

async fn health() -> Json<serde_json::Value> {
    Json(
        json!({ "service": "saarathi-rides", "status": "ok", "version": env!("CARGO_PKG_VERSION") }),
    )
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/v1/ws", get(ws::ws_handler))
        .merge(rides::routes())
        .merge(delivery::routes())
        .merge(ledger::routes())
        .merge(dispatch::routes())
        .merge(flags::routes())
        .merge(surge::routes())
        .merge(metrics::routes())
        .merge(tracking::routes())
        .merge(safety::routes())
        .merge(feedback::routes())
        .merge(analytics::routes())
        .merge(subscription::routes())
        .merge(plans::routes())
        .merge(insights::routes())
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}
