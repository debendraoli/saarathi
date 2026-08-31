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
//! Every message here is broadcast-only (persisted to `trip_events`, fanned
//! out to every subscriber) — `location`/`status`/bidding mutations go over
//! plain HTTP (see `routes::tracking`/`routes::rides`/`routes::bidding`),
//! which already has client-side retry/backoff; a request/reply ack protocol
//! on top of this socket wasn't worth the added complexity for how
//! infrequently those requests actually fire.

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

    match is_participant(&st, q.trip, &claims).await {
        Ok(true) => {}
        _ => return (StatusCode::FORBIDDEN, "not a trip participant").into_response(),
    }

    let uid = claims.sub;
    let trip = q.trip;
    ws.on_upgrade(move |socket| socket_loop(socket, st, uid, trip))
}

/// Same access rule as `get_trip`/`get_participants` in routes/rides.rs
/// (rider, driver, staff, or — for a delivery trip — the fulfilling
/// merchant): this WS is just a different transport for the same trip view,
/// not a separate capability with its own rules.
async fn is_participant(
    st: &AppState,
    trip: Uuid,
    claims: &saarathi_core::authn::Claims,
) -> anyhow::Result<bool> {
    let row: Option<(Uuid, Option<Uuid>, String)> =
        sqlx::query_as("SELECT rider_id, driver_id, trip_type::text FROM trips WHERE id = $1")
            .bind(trip)
            .fetch_optional(&st.db)
            .await?;
    let Some((rider, driver, trip_type)) = row else {
        return Ok(false);
    };
    if rider == claims.sub || driver == Some(claims.sub) || claims.is_staff() {
        return Ok(true);
    }
    if trip_type == "delivery" {
        let owns: Option<Uuid> = sqlx::query_scalar(
            "SELECT m.id FROM orders o JOIN merchants m ON m.id = o.merchant_id \
             WHERE o.trip_id = $1 AND m.owner_user_id = $2",
        )
        .bind(trip)
        .bind(claims.sub)
        .fetch_optional(&st.db)
        .await?;
        return Ok(owns.is_some());
    }
    Ok(false)
}

async fn socket_loop(socket: WebSocket, st: AppState, uid: Uuid, trip: Uuid) {
    let (mut sink, mut stream) = socket.split();
    let mut rx = st.hub.subscribe("trip", trip).await;
    // Per-user room a staff suspend/ban publishes to (see
    // `user_status_sub::run`) so this socket force-closes immediately rather
    // than waiting for the access token to expire or the next refresh.
    let mut account_rx = st.hub.subscribe("account", uid).await;

    // Forward broadcast messages to this client; close outright on an
    // account-status signal instead of forwarding it as a trip event.
    let send_task = tokio::spawn(async move {
        loop {
            tokio::select! {
                msg = rx.recv() => {
                    match msg {
                        Some(msg) => {
                            if sink.send(Message::Text(msg.into())).await.is_err() {
                                break;
                            }
                        }
                        None => break,
                    }
                }
                msg = account_rx.recv() => {
                    if msg.is_some() {
                        let _ = sink.send(Message::Close(None)).await;
                    }
                    break;
                }
            }
        }
    });

    st.hub.publish(
        "trip",
        trip,
        json!({ "type": "presence", "event": "join", "sender_id": uid }).to_string(),
    );

    // Also mark this user reachable in-app for the notify service's push
    // suppression (`saarathi_core::presence`) — separate from the trip-room
    // "presence" broadcast event above, which is peer-facing UI, not a
    // cross-service signal. Refreshed periodically since a socket can sit
    // idle a long time (e.g. a rider just watching the map) with no inbound
    // client messages to piggyback the refresh on.
    let mut presence_conn = st.redis.clone();
    saarathi_core::presence::mark_online(&mut presence_conn, uid).await;
    let mut ticker = tokio::time::interval(std::time::Duration::from_secs(20));
    ticker.tick().await;

    loop {
        tokio::select! {
            msg = stream.next() => {
                match msg {
                    Some(Ok(Message::Text(text))) => {
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
                        st.hub.publish("trip", trip, enriched.to_string());
                    }
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Err(_)) => break,
                    Some(Ok(_)) => {}
                }
            }
            _ = ticker.tick() => {
                saarathi_core::presence::mark_online(&mut presence_conn, uid).await;
            }
        }
    }

    send_task.abort();
    saarathi_core::presence::mark_offline(&mut presence_conn, uid).await;
    st.hub.publish(
        "trip",
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
