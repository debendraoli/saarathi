//! Inter-service events carried over NATS.
//!
//! The first event bus use: **notifications**. The rides service publishes a
//! [`NotifyRequest`] to [`NOTIFY_SUBJECT`]; the standalone `saarathi-notify`
//! service consumes it, writes the durable inbox row, and escalates critical
//! classes to push/SMS. Keeping the contract here means both sides can't drift.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// NATS subject for notification delivery requests.
pub const NOTIFY_SUBJECT: &str = "saarathi.notify.v1";

/// A request to deliver one notification to one user.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NotifyRequest {
    pub user_id: Uuid,
    pub class: String,
    pub title: String,
    pub body: String,
}
