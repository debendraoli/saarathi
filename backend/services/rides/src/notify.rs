//! Notification publishing. Trips don't write the inbox anymore — they publish a
//! `NotifyRequest` to NATS and the standalone `saarathi-notify` service persists
//! it and runs the push/SMS ladder. Fire-and-forget: a bus blip never fails a
//! ride.

use saarathi_core::events::{NotifyRequest, NOTIFY_SUBJECT};
use uuid::Uuid;

/// Publish a notification request for `user_id` onto the bus. No-op (logged) if
/// NATS isn't connected. `link`, when given, is the `saarathi://…` deep link a
/// tap on the notification should open.
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
