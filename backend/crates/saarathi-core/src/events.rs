//! Inter-service events carried over NATS.
//!
//! The first event bus use: **notifications**. The rides service publishes a
//! [`NotifyRequest`] to [`NOTIFY_SUBJECT`]; the standalone `saarathi-notify`
//! service consumes it, writes the durable inbox row, and escalates critical
//! classes to push/SMS. Keeping the contract here means both sides can't drift.

use serde::{Deserialize, Serialize};
use serde_json::Value;
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
    /// Deep link the client should open on tap, e.g. `saarathi://trip/<id>`.
    /// `None` for notifications with nothing to navigate to (safety pings,
    /// marketing copy).
    #[serde(default)]
    pub link: Option<String>,
    /// Arbitrary payload for a device-to-device signal (e.g. a forced
    /// sign-out) rather than user-facing content. Only meaningful when
    /// [`silent`] is set.
    #[serde(default)]
    pub data: Option<Value>,
    /// A device-only signal: skip the durable inbox row and the
    /// critical-class SMS fallback, and send FCM as a data-only message
    /// (no visible tray notification) instead of the usual title/body one.
    #[serde(default)]
    pub silent: bool,
}
