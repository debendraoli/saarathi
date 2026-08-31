//! Realtime hub: id-scoped fan-out for WebSocket layers across services
//! (rides' trip/driver sockets, notify's staff socket, and anything else
//! that needs "push this to whoever's listening for this id" later).
//!
//! Backed by NATS core pub/sub so a message published on any node/service
//! reaches every subscriber on every node — two peers (or two different
//! services) can be connected to different replicas and still see each
//! other. This makes the realtime path horizontally scalable and fault
//! tolerant regardless of node count.
//!
//! When NATS is unavailable (e.g. a single-node dev box without the bus), it
//! degrades to an in-process broadcast channel so the same node still works
//! (cross-service/cross-node fan-out is lost in that degraded mode, same
//! trade-off the trip/driver sockets already accepted before this moved
//! here).
//!
//! Rooms are namespaced by an explicit `room` string chosen by the caller
//! (e.g. "trip", "driver", "staff") so different concerns never collide on
//! the same NATS subject even if their ids happen to coincide (they won't,
//! since these are all random UUIDs, but the namespace also just makes the
//! subject self-describing for anyone watching the bus).

use futures_util::StreamExt;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::sync::broadcast;
use uuid::Uuid;

fn subject(room: &str, id: Uuid) -> String {
    format!("saarathi.rt.{room}.{id}")
}

type RoomMap = HashMap<(String, Uuid), broadcast::Sender<String>>;

#[derive(Clone)]
pub struct Hub {
    /// Present in production; drives cross-node/cross-service fan-out.
    nats: Option<async_nats::Client>,
    /// In-process fallback, used only when NATS is absent.
    rooms: Arc<Mutex<RoomMap>>,
}

impl Hub {
    pub fn new(nats: Option<async_nats::Client>) -> Self {
        Self {
            nats,
            rooms: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn local_sender(&self, room: &str, id: Uuid) -> broadcast::Sender<String> {
        let mut rooms = self.rooms.lock().expect("hub lock");
        rooms
            .entry((room.to_string(), id))
            .or_insert_with(|| broadcast::channel(128).0)
            .clone()
    }

    /// Start receiving this room+id's realtime messages. Dropping the
    /// returned `Subscription` unsubscribes (NATS sends UNSUB on drop).
    pub async fn subscribe(&self, room: &str, id: Uuid) -> Subscription {
        if let Some(nats) = &self.nats {
            match nats.subscribe(subject(room, id)).await {
                Ok(sub) => return Subscription::Nats(sub),
                Err(e) => {
                    tracing::warn!(error = %e, %room, %id, "hub: NATS subscribe failed; using local room")
                }
            }
        }
        Subscription::Local(self.local_sender(room, id).subscribe())
    }

    /// Fan a message out to everyone watching this room+id, on any node or
    /// service. Fire-and-forget: a slow/broken bus must never block a
    /// request handler.
    pub fn publish(&self, room: &str, id: Uuid, msg: String) {
        if let Some(nats) = &self.nats {
            let nats = nats.clone();
            let subj = subject(room, id);
            tokio::spawn(async move {
                if let Err(e) = nats.publish(subj, msg.into()).await {
                    tracing::warn!(error = %e, "hub: NATS publish failed");
                }
            });
        } else {
            let _ = self.local_sender(room, id).send(msg);
        }
    }
}

/// A live subscription to a room+id, from either transport.
pub enum Subscription {
    Nats(async_nats::Subscriber),
    Local(broadcast::Receiver<String>),
}

impl Subscription {
    /// Next message, or `None` when the room closes.
    pub async fn recv(&mut self) -> Option<String> {
        match self {
            Subscription::Nats(sub) => sub
                .next()
                .await
                .map(|m| String::from_utf8_lossy(&m.payload).into_owned()),
            // Skip lag (dropped messages) rather than tearing down the socket.
            Subscription::Local(rx) => loop {
                match rx.recv().await {
                    Ok(msg) => return Some(msg),
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => return None,
                }
            },
        }
    }
}
