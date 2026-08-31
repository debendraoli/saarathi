//! Notification publishing. Mirrors rides'/merchant's/places'/payments'
//! notify.rs: a KYC decision doesn't write the inbox directly, it publishes a
//! `NotifyRequest` to NATS and the standalone `saarathi-notify` service
//! persists it and runs the push ladder. Fire-and-forget: a bus blip never
//! fails an approval.

use saarathi_core::events::{
    NotifyRequest, UserStatusChanged, NOTIFY_SUBJECT, USER_STATUS_CHANGED_SUBJECT,
};
use uuid::Uuid;

pub async fn send(
    nats: &Option<async_nats::Client>,
    user_id: Uuid,
    class: &str,
    title: &str,
    body: &str,
    link: Option<String>,
) {
    let Some(client) = nats else {
        tracing::debug!(%user_id, class, "notification skipped (no NATS)");
        return;
    };
    let req = NotifyRequest {
        user_id,
        class: class.to_string(),
        title: title.to_string(),
        body: body.to_string(),
        link,
        data: None,
        silent: false,
    };
    match serde_json::to_vec(&req) {
        Ok(bytes) => {
            if let Err(e) = client.publish(NOTIFY_SUBJECT, bytes.into()).await {
                tracing::warn!(error = %e, "failed to publish notification");
            }
        }
        Err(e) => tracing::warn!(error = %e, "failed to encode notification"),
    }
}

/// A silent, data-only push — no inbox row, no SMS fallback, no visible
/// tray notification. For device-to-device signals the *other* device
/// needs to react to (e.g. "you were signed out because this account
/// logged in elsewhere"), not content the user should see in their
/// notification list.
pub async fn send_silent(nats: &Option<async_nats::Client>, user_id: Uuid, data: serde_json::Value) {
    let Some(client) = nats else {
        tracing::debug!(%user_id, "silent notification skipped (no NATS)");
        return;
    };
    let req = NotifyRequest {
        user_id,
        class: saarathi_core::domain::notif::TRANSACTIONAL.to_string(),
        title: String::new(),
        body: String::new(),
        link: None,
        data: Some(data),
        silent: true,
    };
    match serde_json::to_vec(&req) {
        Ok(bytes) => {
            if let Err(e) = client.publish(NOTIFY_SUBJECT, bytes.into()).await {
                tracing::warn!(error = %e, "failed to publish silent notification");
            }
        }
        Err(e) => tracing::warn!(error = %e, "failed to encode silent notification"),
    }
}

/// Fire the machine-readable status-change event, separate from the
/// user-facing `send()` push above — `rides` subscribes to this to force-close
/// a suspended/banned user's live WebSockets, and `notify` reads current
/// `users.status` itself before pushing, so this isn't about content, only
/// about telling other services this account's status just changed.
pub async fn publish_status_changed(nats: &Option<async_nats::Client>, user_id: Uuid, status: &str) {
    let Some(client) = nats else {
        tracing::debug!(%user_id, status, "status-changed event skipped (no NATS)");
        return;
    };
    let evt = UserStatusChanged {
        user_id,
        status: status.to_string(),
    };
    match serde_json::to_vec(&evt) {
        Ok(bytes) => {
            if let Err(e) = client.publish(USER_STATUS_CHANGED_SUBJECT, bytes.into()).await {
                tracing::warn!(error = %e, "failed to publish status-changed event");
            }
        }
        Err(e) => tracing::warn!(error = %e, "failed to encode status-changed event"),
    }
}
