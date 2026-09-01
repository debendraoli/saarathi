//! Thin per-service wiring for the shared JWT extractors — see
//! `saarathi_core::authn`, the single implementation every service used to
//! duplicate.

use crate::state::AppState;

pub use saarathi_core::authn::{AdminUser, AuthUser, Claims, StaffUser, verify_access};

impl saarathi_core::authn::HasJwtSecret for AppState {
    fn jwt_secret(&self) -> &str {
        &self.config.jwt_secret
    }
}
