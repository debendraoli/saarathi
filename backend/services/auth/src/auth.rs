//! Thin re-export of the shared JWT extractors — see `saarathi_core::authn`,
//! the single implementation every service (including this one, the token
//! issuer) uses for verification. `HasJwtSecret` for `AppState` lives in
//! `crate::state` alongside the state definition it applies to.

pub use saarathi_core::authn::{AuthUser, StaffUser};
