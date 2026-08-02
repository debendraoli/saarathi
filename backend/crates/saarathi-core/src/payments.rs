//! Payment-service-provider hand-off, shared by every service that starts a
//! top-up or payout. Real providers (eSewa/Khalti/Fonepay/ConnectIPS) return a
//! checkout URL/token and confirm asynchronously via a signed webhook. The
//! `MockProvider` lets the whole flow run end-to-end in dev/test.

use rust_decimal::Decimal;
use uuid::Uuid;

pub trait PaymentProvider: Send + Sync {
    fn name(&self) -> &'static str;
    /// Begin a top-up; returns an opaque reference the client uses to pay.
    fn start_topup(&self, user_id: Uuid, amount: Decimal) -> String;
    /// Begin a payout; returns a provider reference.
    fn start_payout(&self, recipient_id: Uuid, amount: Decimal) -> String;
}

/// Dev/test provider — references are UUIDs and payouts settle instantly.
pub struct MockProvider;

impl PaymentProvider for MockProvider {
    fn name(&self) -> &'static str {
        "mock"
    }
    fn start_topup(&self, _user_id: Uuid, _amount: Decimal) -> String {
        Uuid::new_v4().to_string()
    }
    fn start_payout(&self, _recipient_id: Uuid, _amount: Decimal) -> String {
        Uuid::new_v4().to_string()
    }
}
