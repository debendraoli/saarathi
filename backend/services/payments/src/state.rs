//! Shared application state for saarathi-payments.

use rust_decimal::Decimal;
use saarathi_core::payments::PaymentProvider;
use sqlx::PgPool;
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub db: PgPool,
    pub jwt_secret: Arc<String>,
    pub payments: Arc<dyn PaymentProvider>,
    /// Tax deducted at source on payouts (recipient nets amount − TDS).
    pub tds_rate: Decimal,
    /// NATS bus for topup/payout notifications. `None` if unavailable.
    pub nats: Option<async_nats::Client>,
}
