//! Thin per-service wiring for the shared JWT extractors — see
//! `saarathi_core::authn`, the single implementation every service used to
//! duplicate. Partners' domain calls a `can_approve`-eligible user an
//! "admin" (governs partners), hence `AdminUser` rather than `StaffUser`.

use crate::state::AppState;

pub use saarathi_core::authn::{AdminUser, AuthUser};

impl saarathi_core::authn::HasJwtSecret for AppState {
    fn jwt_secret(&self) -> &str {
        &self.jwt_secret
    }
}
