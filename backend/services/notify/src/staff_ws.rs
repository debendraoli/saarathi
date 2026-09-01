//! Staff-scoped WebSocket: pushes each new notification the instant
//! `deliver()` inserts it, instead of the dashboard's own 20s poll of
//! `GET /v1/notifications` discovering it later.
//!
//! Connect: `GET /v1/staff/ws?token=<jwt>` (staff roles only — same
//! `Claims::is_staff()` check the trip socket already uses for a staff
//! member joining a specific trip; this is the same idea but not scoped to
//! any one trip). Receive-only from the client's perspective, same as
//! `rides::driver_ws` — nothing meaningful is expected back on this socket.
//!
//! Published on the "staff" room, keyed by the recipient's own user id (see
//! `deliver()` in `main.rs`) — each staff member only receives their own
//! notifications, same as the inbox they'd otherwise poll for.

use crate::AppState;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use futures_util::{SinkExt, StreamExt};
use saarathi_core::authn::{HasJwtSecret, verify_access};
use serde::Deserialize;

#[derive(Deserialize)]
pub struct StaffWsQuery {
    token: String,
}

pub async fn staff_ws_handler(
    State(st): State<AppState>,
    Query(q): Query<StaffWsQuery>,
    ws: WebSocketUpgrade,
) -> Response {
    let claims = match verify_access(st.jwt_secret(), &q.token) {
        Ok(c) => c,
        Err(_) => return (StatusCode::UNAUTHORIZED, "unauthorized").into_response(),
    };
    if !claims.is_staff() {
        return (StatusCode::FORBIDDEN, "staff only").into_response();
    }
    let staff_id = claims.sub;
    ws.on_upgrade(move |socket| staff_socket_loop(socket, st, staff_id))
}

async fn staff_socket_loop(socket: WebSocket, st: AppState, staff_id: uuid::Uuid) {
    let (mut sink, mut stream) = socket.split();
    let mut rx = st.hub.subscribe("staff", staff_id).await;

    let send_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if sink.send(Message::Text(msg.into())).await.is_err() {
                break;
            }
        }
    });

    // Nothing meaningful arrives from the client on this socket — it exists
    // purely to receive pushes — so just wait for it to close.
    while let Some(msg) = stream.next().await {
        match msg {
            Ok(Message::Close(_)) => break,
            Ok(_) => {}
            Err(_) => break,
        }
    }

    send_task.abort();
}
