//! Thin re-export of the shared JWT extractors — see `saarathi_core::authn`,
//! the single implementation every service uses for verification.
//! `HasJwtSecret` for `AppState` lives in `crate::state`.

pub use saarathi_core::authn::{AdminUser, AuthUser, StaffUser};
