//! Realtime hub: trip-scoped fan-out for the WebSocket layer (location, status,
//! chat, WebRTC signaling).
//!
//! Backed by NATS core pub/sub so a message published on any node reaches every
//! subscriber on every node — the two WS peers of a trip can be connected to
//! different `rides` replicas and still see each other. This makes the realtime
//! path horizontally scalable and fault tolerant regardless of node count.
//!
//! When NATS is unavailable (e.g. a single-node dev box without the bus), it
//! degrades to an in-process broadcast channel so the same node still works.

use futures_util::StreamExt;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::sync::broadcast;
use uuid::Uuid;

/// NATS subject for a trip's realtime room. UUIDs contain only hex + hyphens,
/// so they're valid single-token subject suffixes.
fn subject(trip: Uuid) -> String {
    format!("saarathi.rt.trip.{trip}")
}

#[derive(Clone)]
pub struct Hub {
    /// Present in production; drives cross-node fan-out.
    nats: Option<async_nats::Client>,
    /// In-process fallback, used only when NATS is absent.
    rooms: Arc<Mutex<HashMap<Uuid, broadcast::Sender<String>>>>,
}

impl Hub {
    pub fn new(nats: Option<async_nats::Client>) -> Self {
        Self {
            nats,
            rooms: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn local_sender(&self, trip: Uuid) -> broadcast::Sender<String> {
        let mut rooms = self.rooms.lock().expect("hub lock");
        rooms
            .entry(trip)
            .or_insert_with(|| broadcast::channel(128).0)
            .clone()
    }

    /// Start receiving this trip's realtime messages. Dropping the returned
    /// `Subscription` unsubscribes (NATS sends UNSUB on drop).
    pub async fn subscribe(&self, trip: Uuid) -> Subscription {
        if let Some(nats) = &self.nats {
            match nats.subscribe(subject(trip)).await {
                Ok(sub) => return Subscription::Nats(sub),
                Err(e) => {
                    tracing::warn!(error = %e, %trip, "hub: NATS subscribe failed; using local room")
                }
            }
        }
        Subscription::Local(self.local_sender(trip).subscribe())
    }

    /// Fan a message out to everyone watching this trip, on any node.
    /// Fire-and-forget: a slow/broken bus must never block a request handler.
    pub fn publish(&self, trip: Uuid, msg: String) {
        if let Some(nats) = &self.nats {
            let nats = nats.clone();
            tokio::spawn(async move {
                if let Err(e) = nats.publish(subject(trip), msg.into()).await {
                    tracing::warn!(error = %e, %trip, "hub: NATS publish failed");
                }
            });
        } else {
            let _ = self.local_sender(trip).send(msg);
        }
    }
}

/// A live subscription to a trip room, from either transport.
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
