//! Service-to-service API — **not** registered in the gateway (see
//! `backend/traefik/dynamic/routes.yml`; the same omission-based boundary
//! `saarathi-rides`' own `routes/internal.rs` uses). This is the reverse
//! direction of that one: `spawn_courier` here calls *into* rides to create
//! a delivery trip, and this is what rides calls back into when that same
//! trip gets cancelled during the arrival phase (before pickup) — the order
//! still needs a courier, and nothing else in this service polls for that,
//! so without this call it would just sit stuck with a dead `trip_id`
//! forever.

use crate::error::AppError;
use crate::error::AppResult;
use crate::routes::marketplace::spawn_courier;
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::{Json, Router, routing::post};
use serde_json::{Value, json};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new().route(
        "/v1/internal/orders/{id}/redispatch",
        post(redispatch_order),
    )
}

fn check_internal_secret(st: &AppState, headers: &HeaderMap) -> AppResult<()> {
    if saarathi_core::api::check_internal_secret(&st.config.internal_service_secret, headers) {
        Ok(())
    } else {
        Err(AppError::Forbidden)
    }
}

/// Re-attempts courier dispatch for an order whose previous delivery trip
/// fell through. `spawn_courier` itself is the idempotency guard (bails as
/// a no-op if `orders.trip_id` is already set again by the time this
/// lands), so a duplicate/racing call here is harmless.
async fn redispatch_order(
    State(st): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    check_internal_secret(&st, &headers)?;
    spawn_courier(&st, id).await?;
    Ok(Json(json!({ "ok": true })))
}
