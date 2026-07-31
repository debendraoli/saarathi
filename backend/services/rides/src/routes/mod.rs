//! Router assembly + CORS.

pub mod analytics;
pub mod campaigns;
pub mod dispatch;
pub mod feedback;
pub mod ledger;
pub mod notifications;
pub mod payments;
pub mod rides;
pub mod safety;
pub mod tracking;

use crate::state::AppState;
use crate::ws;
use axum::http::{HeaderName, Method};
use axum::{routing::get, Json, Router};
use serde_json::json;
use tower_http::cors::{AllowOrigin, CorsLayer};
use tower_http::trace::TraceLayer;

async fn health() -> Json<serde_json::Value> {
    Json(
        json!({ "service": "saarathi-rides", "status": "ok", "version": env!("CARGO_PKG_VERSION") }),
    )
}

pub fn router(state: AppState) -> Router {
    let origins: Vec<_> = state
        .config
        .cors_origins
        .iter()
        .filter_map(|o| o.parse().ok())
        .collect();
    let cors = CorsLayer::new()
        .allow_origin(AllowOrigin::list(origins))
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::DELETE,
            Method::OPTIONS,
        ])
        .allow_headers([
            HeaderName::from_static("authorization"),
            HeaderName::from_static("content-type"),
        ]);

    Router::new()
        .route("/health", get(health))
        .route("/v1/ws", get(ws::ws_handler))
        .merge(rides::routes())
        .merge(campaigns::routes())
        .merge(ledger::routes())
        .merge(dispatch::routes())
        .merge(payments::routes())
        .merge(tracking::routes())
        .merge(safety::routes())
        .merge(feedback::routes())
        .merge(notifications::routes())
        .merge(analytics::routes())
        .layer(cors)
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}
