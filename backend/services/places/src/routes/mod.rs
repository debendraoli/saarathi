//! Router assembly.

pub mod admin;
pub mod contributions;

use crate::state::AppState;
use axum::Router;

pub fn router() -> Router<AppState> {
    Router::new()
        .merge(contributions::routes())
        .merge(admin::routes())
}
