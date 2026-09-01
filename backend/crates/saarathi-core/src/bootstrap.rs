//! Small pieces of `main.rs` boilerplate that were being copy-pasted
//! near-identically into every service: an env var with a default, the
//! Postgres pool setup, tracing init, and the `/health` route.

use axum::{Json, Router, routing::get};
use serde_json::{json, Value};
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use std::time::Duration;

/// An env var, or `default` when unset/empty.
pub fn env_or(key: &str, default: &str) -> String {
    std::env::var(key)
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| default.into())
}

/// The pool settings every service already used identically
/// (`max_connections(10)`, a 5s acquire timeout).
pub async fn connect_pg(database_url: &str) -> Result<PgPool, sqlx::Error> {
    PgPoolOptions::new()
        .max_connections(10)
        .acquire_timeout(Duration::from_secs(5))
        .connect(database_url)
        .await
}

/// `tracing_subscriber::fmt()` with the `RUST_LOG`-or-`info` filter every
/// service's `main` set up the same way.
pub fn init_tracing() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();
}

/// A `/health` route returning `{"service": name, "status": "ok"}`, generic
/// over whatever `AppState` a service uses.
pub fn health_router<S>(service_name: &'static str) -> Router<S>
where
    S: Clone + Send + Sync + 'static,
{
    Router::new().route(
        "/health",
        get(move || async move {
            Json::<Value>(json!({ "service": service_name, "status": "ok" }))
        }),
    )
}
