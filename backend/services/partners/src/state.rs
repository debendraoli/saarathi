//! Shared application state for saarathi-partners.

use rust_decimal::Decimal;
use saarathi_core::payments::PaymentProvider;
use sqlx::PgPool;
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub db: PgPool,
    pub jwt_secret: Arc<String>,
    pub payments: Arc<dyn PaymentProvider>,
    /// Tax deducted at source on partner payouts.
    pub tds_rate: Decimal,
}
