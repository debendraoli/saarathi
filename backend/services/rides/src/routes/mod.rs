//! Router assembly + CORS.

pub mod analytics;
pub mod bidding;
pub mod credits;
pub mod delivery;
pub mod dispatch;
pub mod feedback;
pub mod flags;
pub mod geo;
pub mod insights;
pub mod internal;
pub mod ledger;
pub mod metrics;
pub mod plans;
pub mod rates;
pub mod rides;
pub mod rtc;
pub mod safety;
pub mod self_service;
pub mod support;
pub mod surge;
pub mod tracking;

use crate::driver_ws;
use crate::state::AppState;
use crate::ws;
use axum::{routing::get, Json, Router};
use serde_json::json;
use tower_http::{catch_panic::CatchPanicLayer, trace::TraceLayer};

async fn health() -> Json<serde_json::Value> {
    Json(
        json!({ "service": "saarathi-rides", "status": "ok", "version": env!("CARGO_PKG_VERSION") }),
    )
}

pub fn router(state: AppState) -> Router {
    Router::<AppState>::new()
        .route("/health", get(health))
        .route("/v1/ws", get(ws::ws_handler))
        .route("/v1/driver/ws", get(driver_ws::driver_ws_handler))
        .merge(rides::routes())
        .merge(bidding::routes())
        .merge(delivery::routes())
        .merge(ledger::routes())
        .merge(dispatch::routes())
        .merge(flags::routes())
        .merge(surge::routes())
        .merge(metrics::routes())
        .merge(tracking::routes())
        .merge(safety::routes())
        .merge(self_service::routes())
        .merge(support::routes())
        .merge(feedback::routes())
        .merge(analytics::routes())
        .merge(credits::routes())
        .merge(rtc::routes())
        .merge(geo::routes())
        .merge(plans::routes())
        .merge(rates::routes())
        .merge(insights::routes())
        .merge(internal::routes())
        .layer(CatchPanicLayer::new())
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}
