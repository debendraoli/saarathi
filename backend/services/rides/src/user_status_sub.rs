//! Subscribes to `auth`'s account-status events and force-closes this user's
//! live sockets the moment they're suspended/banned, instead of waiting for
//! their access token to expire or the next refresh to reject them (see
//! `saarathi_core::events::UserStatusChanged`). Mirrors `notify`'s `consume`
//! loop shape (`services/notify/src/main.rs`).

use crate::state::AppState;
use futures_util::StreamExt;
use saarathi_core::domain::user_status;
use saarathi_core::events::{USER_STATUS_CHANGED_SUBJECT, UserStatusChanged};
use serde_json::json;

pub async fn run(st: AppState) {
    let Some(nats) = &st.nats else {
        tracing::warn!(
            "user_status_sub: NATS unavailable; account status changes won't force-close sockets"
        );
        return;
    };
    let mut sub = match nats.subscribe(USER_STATUS_CHANGED_SUBJECT).await {
        Ok(s) => s,
        Err(e) => {
            tracing::error!(error = %e, "user_status_sub: failed to subscribe");
            return;
        }
    };
    while let Some(msg) = sub.next().await {
        match serde_json::from_slice::<UserStatusChanged>(&msg.payload) {
            Ok(evt)
                if evt.status == user_status::SUSPENDED || evt.status == user_status::BANNED =>
            {
                st.hub.publish(
                    "account",
                    evt.user_id,
                    json!({ "type": "account_suspended" }).to_string(),
                );
            }
            Ok(_) => {}
            Err(e) => tracing::warn!(error = %e, "user_status_sub: bad UserStatusChanged payload"),
        }
    }
}
