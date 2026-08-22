//! Shared application state. The auth extractors themselves live in
//! `saarathi_core::authn` — see `crate::auth` for this service's wiring.

use crate::config::Config;
use crate::store::DocumentStore;
use sqlx::PgPool;
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub db: PgPool,
    pub config: Arc<Config>,
    pub docs: Arc<dyn DocumentStore>,
    /// NATS bus for contribution-review notifications. `None` if unavailable.
    pub nats: Option<async_nats::Client>,
}

impl saarathi_core::authn::HasJwtSecret for AppState {
    fn jwt_secret(&self) -> &str {
        &self.config.jwt_secret
    }
}
