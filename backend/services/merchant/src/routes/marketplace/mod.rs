//! Marketplace (food / grocery): merchants, menus, and customer orders. An
//! order's courier leg reuses delivery — when it's marked `ready` we call
//! rides' internal `/v1/internal/delivery-trips` API (not the gateway; see
//! that endpoint's docs) so the existing dispatch + settlement plumbing
//! carries it to the customer, without this service reaching into rides'
//! internals directly.

mod admin;
mod items;
mod merchants;
mod orders;

use crate::error::AppResult;
use crate::state::AppState;
use axum::{
    Router,
    routing::{get, post},
};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/merchants", get(merchants::list_merchants))
        .route("/v1/merchants/{id}", get(merchants::merchant_detail))
        .route("/v1/items/search", get(items::search_items))
        .route(
            "/v1/orders",
            get(orders::my_orders).post(orders::place_order),
        )
        .route("/v1/orders/mine/stats", get(orders::my_order_stats))
        .route("/v1/orders/{id}", get(orders::order_detail))
        .route("/v1/orders/{id}/status", post(orders::update_order_status))
        .route("/v1/orders/{id}/rate", post(orders::rate_merchant))
        // Merchant-facing (owner of the merchant, or staff).
        .route("/v1/merchant/merchants", get(merchants::my_merchants))
        .route(
            "/v1/merchant/merchants/{id}/menu",
            get(merchants::merchant_menu),
        )
        .route(
            "/v1/merchant/merchants/{id}/analytics",
            get(merchants::merchant_analytics),
        )
        .route(
            "/v1/merchant/merchants/{id}/offers",
            get(merchants::list_offers).post(merchants::create_offer),
        )
        .route(
            "/v1/merchant/merchants/{id}/offers/{offer_id}/deactivate",
            post(merchants::deactivate_offer),
        )
        .route(
            "/v1/merchants/{id}/offers/active",
            get(merchants::active_offers),
        )
        .route("/v1/offers/nearby", get(merchants::nearby_offers))
        .route("/v1/merchant/orders", get(orders::merchant_orders))
        .route("/v1/merchant/menu", post(merchants::add_menu_item))
        .route(
            "/v1/merchant/menu/{id}/availability",
            post(merchants::set_item_availability),
        )
        .route(
            "/v1/merchant/menu/{id}/photo",
            post(merchants::upload_item_photo),
        )
        .route("/v1/items/{id}/photo", get(items::item_photo))
        .route(
            "/v1/merchant/merchants/{id}/photo",
            post(merchants::upload_merchant_photo),
        )
        .route("/v1/merchants/{id}/photo", get(merchants::merchant_photo))
        .route("/v1/merchant/open", post(merchants::set_open))
        // Self-service onboarding (any signed-in user can register a store).
        .route("/v1/merchant/apply", post(merchants::apply_merchant))
        // Ops onboarding.
        .route("/v1/admin/merchants", post(admin::create_merchant))
        // Staff review queue.
        .route("/v1/admin/merchants/queue", get(admin::merchant_queue))
        .route(
            "/v1/admin/merchants/{id}/approve",
            post(admin::approve_merchant),
        )
        .route(
            "/v1/admin/merchants/{id}/reject",
            post(admin::reject_merchant),
        )
        .route(
            "/v1/admin/merchants/{id}",
            axum::routing::patch(admin::update_merchant),
        )
}

/// True when the user owns the merchant (or is staff).
pub(crate) async fn owns_or_staff(
    st: &AppState,
    uid: Uuid,
    is_staff: bool,
    merchant_id: Uuid,
) -> AppResult<bool> {
    if is_staff {
        return Ok(true);
    }
    let owner: Option<Option<Uuid>> =
        sqlx::query_scalar("SELECT owner_user_id FROM merchants WHERE id = $1")
            .bind(merchant_id)
            .fetch_optional(&st.db)
            .await?;
    Ok(matches!(owner, Some(Some(o)) if o == uid))
}

// Re-exported so existing `crate::routes::marketplace::spawn_courier` callers
// (e.g. routes/internal.rs) keep working now that it lives in `orders`.
pub(crate) use orders::spawn_courier;
