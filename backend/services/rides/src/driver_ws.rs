//! Driver-scoped WebSocket: connected for as long as the driver app
//! considers itself online, independent of any specific trip — unlike
//! `ws.rs`'s trip-scoped socket, which only exists once a driver is already
//! attached to a particular trip. This is what lets a dispatch offer reach
//! the driver the instant it's created (see `dispatch::dispatch_trip`'s
//! `st.hub.publish(driver_id, ...)`) instead of only ever being discovered
//! by the driver app's fallback poll (`GET /v1/driver/offers`).
//!
//! Connect: `GET /v1/driver/ws?token=<jwt>` (driver role only). Receive-only
//! from the client's perspective — going online/offline, heartbeats, and
//! everything else still go over plain HTTP (`routes::dispatch`); this
//! socket exists purely so a push has somewhere to land instantly instead
//! of waiting for the next poll tick.
//! Messages the client receives:
//!   { "type": "offer", "trip_id": .., .. }

use crate::auth::verify_access;
use crate::state::AppState;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use futures_util::{SinkExt, StreamExt};
use saarathi_core::domain::roles;
use serde::Deserialize;

#[derive(Deserialize)]
pub struct DriverWsQuery {
    token: String,
}

pub async fn driver_ws_handler(
    State(st): State<AppState>,
    Query(q): Query<DriverWsQuery>,
    ws: WebSocketUpgrade,
) -> Response {
    let claims = match verify_access(&st.config.jwt_secret, &q.token) {
        Ok(c) => c,
        Err(_) => return (StatusCode::UNAUTHORIZED, "unauthorized").into_response(),
    };
    if claims.role != roles::DRIVER {
        return (StatusCode::FORBIDDEN, "drivers only").into_response();
    }
    let driver_id = claims.sub;
    ws.on_upgrade(move |socket| driver_socket_loop(socket, st, driver_id))
}

async fn driver_socket_loop(socket: WebSocket, st: AppState, driver_id: uuid::Uuid) {
    let (mut sink, mut stream) = socket.split();
    let mut rx = st.hub.subscribe(driver_id).await;

    let mut presence_conn = st.redis.clone();
    saarathi_core::presence::mark_online(&mut presence_conn, driver_id).await;

    // Forward every push (offers, and anything else later published to this
    // driver's channel) straight to the client.
    let send_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if sink.send(Message::Text(msg.into())).await.is_err() {
                break;
            }
        }
    });

    // Nothing meaningful arrives from the client on this socket — it exists
    // purely to receive pushes — so just wait for it to close. Refresh the
    // presence mark periodically so a long-lived idle connection doesn't
    // expire out from under a still-online driver.
    let mut ticker = tokio::time::interval(std::time::Duration::from_secs(20));
    ticker.tick().await; // first tick fires immediately; skip it, we just marked online
    loop {
        tokio::select! {
            msg = stream.next() => {
                match msg {
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Ok(_)) => {}
                    Some(Err(_)) => break,
                }
            }
            _ = ticker.tick() => {
                saarathi_core::presence::mark_online(&mut presence_conn, driver_id).await;
            }
        }
    }

    send_task.abort();
    saarathi_core::presence::mark_offline(&mut presence_conn, driver_id).await;
}
