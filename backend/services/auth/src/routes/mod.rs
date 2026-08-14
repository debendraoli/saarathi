//! Router assembly.

pub mod admin_routes;
pub mod auth_routes;
pub mod driver_routes;
pub mod rider_routes;

use crate::state::AppState;
use axum::{routing::get, Json, Router};
use serde_json::json;
use tower_http::{catch_panic::CatchPanicLayer, trace::TraceLayer};

async fn health() -> Json<serde_json::Value> {
    Json(
        json!({ "service": "saarathi-auth", "status": "ok", "version": env!("CARGO_PKG_VERSION") }),
    )
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health))
        .merge(auth_routes::routes())
        .merge(rider_routes::routes())
        .merge(driver_routes::routes())
        .merge(admin_routes::routes())
        .layer(CatchPanicLayer::new())
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}
