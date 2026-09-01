//! Staff dashboard endpoints: driver verification queue, decisions, document
//! viewing. All decisions are audit-logged and role-gated (RBAC).

mod documents;
mod drivers;
mod staff;

use crate::state::AppState;
use axum::Router;
use axum::routing::{get, patch, post};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/admin/drivers", get(drivers::list_drivers))
        .route("/v1/admin/drivers/onboard", post(drivers::onboard_driver))
        .route(
            "/v1/admin/drivers/{id}",
            get(drivers::driver_detail).patch(drivers::update_driver),
        )
        .route(
            "/v1/admin/drivers/{id}/approve",
            post(drivers::approve_driver),
        )
        .route(
            "/v1/admin/drivers/{id}/reject",
            post(drivers::reject_driver),
        )
        .route(
            "/v1/admin/drivers/{id}/suspend",
            post(drivers::suspend_driver),
        )
        .route(
            "/v1/admin/drivers/{id}/reactivate",
            post(drivers::reactivate_driver),
        )
        .route(
            "/v1/admin/drivers/{id}/service-types",
            post(drivers::update_service_types),
        )
        .route(
            "/v1/admin/drivers/{id}/documents",
            post(documents::upload_driver_document),
        )
        .route(
            "/v1/admin/documents/{id}/content",
            get(documents::document_content),
        )
        .route(
            "/v1/admin/staff",
            get(staff::list_staff).post(staff::create_staff),
        )
        .route("/v1/admin/staff/{id}", patch(staff::update_staff))
        .route(
            "/v1/admin/staff/{id}/deactivate",
            post(staff::deactivate_staff),
        )
        .route(
            "/v1/admin/staff/{id}/reactivate",
            post(staff::reactivate_staff),
        )
}
