//! Router assembly + CORS.

pub mod admin_routes;
pub mod auth_routes;
pub mod driver_routes;
pub mod rider_routes;

use crate::state::AppState;
use axum::http::{HeaderName, Method};
use axum::{routing::get, Json, Router};
use serde_json::json;
use tower_http::cors::{AllowOrigin, CorsLayer};
use tower_http::trace::TraceLayer;

async fn health() -> Json<serde_json::Value> {
    Json(json!({ "service": "saarathi-auth", "status": "ok", "version": env!("CARGO_PKG_VERSION") }))
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
        .allow_methods([Method::GET, Method::POST, Method::PUT, Method::DELETE, Method::OPTIONS])
        .allow_headers([
            HeaderName::from_static("authorization"),
            HeaderName::from_static("content-type"),
        ]);

    Router::new()
        .route("/health", get(health))
        .merge(auth_routes::routes())
        .merge(rider_routes::routes())
        .merge(driver_routes::routes())
        .merge(admin_routes::routes())
        .layer(cors)
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}
