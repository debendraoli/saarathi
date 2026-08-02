//! Trip-scoped WebSocket: near-realtime driver/rider updates, chat, and WebRTC
//! signaling (SDP/ICE) for masked peer-to-peer voice/video. Media stays P2P;
//! this server only relays signaling and status.
//!
//! Connect: `GET /v1/ws?token=<jwt>&trip=<uuid>`
//! Messages are JSON envelopes with a `type` field:
//!   { "type": "location", "lat": .., "lng": .. }   // driver → rider live position
//!   { "type": "status",   "status": "arriving" }    // ride state changes
//!   { "type": "chat",     "body": "on my way" }     // masked text chat
//!   { "type": "signal",   "kind": "offer"|"answer"|"ice", "data": {..} }  // WebRTC
//! The server stamps `sender_id` and fans each message out to both peers.

use crate::auth::verify_access;
use crate::state::AppState;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

#[derive(Deserialize)]
pub struct WsQuery {
    token: String,
    trip: Uuid,
}

pub async fn ws_handler(
    State(st): State<AppState>,
    Query(q): Query<WsQuery>,
    ws: WebSocketUpgrade,
) -> Response {
    let claims = match verify_access(&st.config.jwt_secret, &q.token) {
        Ok(c) => c,
        Err(_) => return (StatusCode::UNAUTHORIZED, "unauthorized").into_response(),
    };

    match is_participant(&st, q.trip, claims.sub).await {
        Ok(true) => {}
        _ => return (StatusCode::FORBIDDEN, "not a trip participant").into_response(),
    }

    let uid = claims.sub;
    let trip = q.trip;
    ws.on_upgrade(move |socket| socket_loop(socket, st, uid, trip))
}

async fn is_participant(st: &AppState, trip: Uuid, uid: Uuid) -> anyhow::Result<bool> {
    let row: Option<(Uuid, Option<Uuid>)> =
        sqlx::query_as("SELECT rider_id, driver_id FROM trips WHERE id = $1")
            .bind(trip)
            .fetch_optional(&st.db)
            .await?;
    Ok(match row {
        Some((rider, driver)) => rider == uid || driver == Some(uid),
        None => false,
    })
}

async fn socket_loop(socket: WebSocket, st: AppState, uid: Uuid, trip: Uuid) {
    let (mut sink, mut stream) = socket.split();
    let mut rx = st.hub.subscribe(trip).await;

    // Forward broadcast messages to this client.
    let send_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if sink.send(Message::Text(msg.into())).await.is_err() {
                break;
            }
        }
    });

    st.hub.publish(
        trip,
        json!({ "type": "presence", "event": "join", "sender_id": uid }).to_string(),
    );

    while let Some(Ok(msg)) = stream.next().await {
        match msg {
            Message::Text(text) => {
                let enriched = enrich(text.as_str(), uid);
                let kind = enriched
                    .get("type")
                    .and_then(Value::as_str)
                    .unwrap_or("event")
                    .to_string();
                let _ = sqlx::query(
                    "INSERT INTO trip_events (trip_id, sender_id, kind, payload) VALUES ($1, $2, $3, $4)",
                )
                .bind(trip)
                .bind(uid)
                .bind(&kind)
                .bind(&enriched)
                .execute(&st.db)
                .await;
                st.hub.publish(trip, enriched.to_string());
            }
            Message::Close(_) => break,
            _ => {}
        }
    }

    send_task.abort();
    st.hub.publish(
        trip,
        json!({ "type": "presence", "event": "leave", "sender_id": uid }).to_string(),
    );
}

fn enrich(raw: &str, uid: Uuid) -> Value {
    let mut v: Value =
        serde_json::from_str(raw).unwrap_or_else(|_| json!({ "type": "chat", "body": raw }));
    if !v.is_object() {
        v = json!({ "type": "message", "data": v });
    }
    v["sender_id"] = json!(uid);
    v
}
