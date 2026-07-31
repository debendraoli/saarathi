//! Shared application state.

use crate::config::Config;
use crate::hub::Hub;
use crate::routing::Router;
use sqlx::PgPool;
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub db: PgPool,
    pub config: Arc<Config>,
    pub router: Arc<Router>,
    pub hub: Hub,
    pub redis: redis::aio::ConnectionManager,
}
