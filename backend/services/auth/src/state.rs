//! Shared application state. The auth extractors themselves live in
//! `saarathi_core::authn` — see `crate::auth` for this service's wiring.

use crate::config::Config;
use crate::otp_delivery::OtpDelivery;
use crate::store::DocumentStore;
use sqlx::PgPool;
use std::sync::Arc;

// Re-exported so existing `crate::state::{AuthUser, StaffUser}` imports keep
// working — the extractors themselves now live in `crate::auth` (a thin
// wrapper over `saarathi_core::authn`).
pub use crate::auth::{AdminUser, AuthUser, StaffUser};

#[derive(Clone)]
pub struct AppState {
    pub db: PgPool,
    pub config: Arc<Config>,
    pub docs: Arc<dyn DocumentStore>,
    /// `None` if Redis was unreachable at boot — the token-bucket OTP rate
    /// limiter fails open in that case (see `crate::rate_limit`).
    pub redis: Option<redis::aio::ConnectionManager>,
    pub otp_delivery: Arc<OtpDelivery>,
    /// NATS bus for KYC-decision notifications. `None` if unavailable.
    pub nats: Option<async_nats::Client>,
}

impl saarathi_core::authn::HasJwtSecret for AppState {
    fn jwt_secret(&self) -> &str {
        &self.config.jwt_secret
    }
}
