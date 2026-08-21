//! Router assembly.

pub mod marketplace;
pub mod zone;

use crate::state::AppState;
use axum::Router;

pub fn router() -> Router<AppState> {
    Router::new()
        .merge(marketplace::routes())
        .merge(zone::routes())
}
