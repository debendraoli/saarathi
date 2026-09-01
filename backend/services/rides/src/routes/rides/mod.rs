//! Ride lifecycle + fare estimate endpoints.

mod crud;
mod driver;
mod estimate;
mod shared;
mod stats;

pub(crate) use crud::complete_trip;

use crate::state::AppState;
use axum::{
    Router,
    routing::{get, post},
};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/rides/estimate", post(estimate::estimate))
        .route("/v1/rides/route", post(estimate::route_geometry))
        .route("/v1/rides", post(crud::create).get(crud::list_mine))
        .route("/v1/rides/mine/stats", get(stats::my_stats))
        .route("/v1/rides/driver/today", get(driver::driver_today))
        .route("/v1/rides/driver/earnings", get(driver::driver_earnings))
        .route("/v1/rides/{id}", get(crud::get_trip))
        .route("/v1/rides/{id}/participants", get(crud::get_participants))
        .route("/v1/rides/{id}/status", post(crud::update_status))
}
