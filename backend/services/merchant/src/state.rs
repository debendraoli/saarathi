//! Shared application state. The auth extractors themselves live in
//! `saarathi_core::authn` — see `crate::auth` for this service's wiring.

use crate::config::Config;
use crate::store::DocumentStore;
use saarathi_core::routing::RoutingClient;
use sqlx::PgPool;
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub db: PgPool,
    pub config: Arc<Config>,
    pub redis: redis::aio::ConnectionManager,
    pub router: Arc<RoutingClient>,
    pub http: reqwest::Client,
    /// NATS bus for order-lifecycle notifications. `None` if unavailable.
    pub nats: Option<async_nats::Client>,
    pub docs: Arc<dyn DocumentStore>,
}

impl saarathi_core::authn::HasJwtSecret for AppState {
    fn jwt_secret(&self) -> &str {
        &self.config.jwt_secret
    }
}
