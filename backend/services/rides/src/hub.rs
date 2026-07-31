//! In-memory realtime hub: one broadcast channel per trip. Good enough for a
//! single node in a low-traffic region; swap for NATS/Redis when we scale out.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::sync::broadcast;
use uuid::Uuid;

#[derive(Clone, Default)]
pub struct Hub {
    rooms: Arc<Mutex<HashMap<Uuid, broadcast::Sender<String>>>>,
}

impl Hub {
    pub fn new() -> Self {
        Self::default()
    }

    fn sender(&self, trip: Uuid) -> broadcast::Sender<String> {
        let mut rooms = self.rooms.lock().expect("hub lock");
        rooms
            .entry(trip)
            .or_insert_with(|| broadcast::channel(128).0)
            .clone()
    }

    pub fn subscribe(&self, trip: Uuid) -> broadcast::Receiver<String> {
        self.sender(trip).subscribe()
    }

    /// Fan a message out to everyone currently watching this trip.
    pub fn publish(&self, trip: Uuid, msg: String) {
        let _ = self.sender(trip).send(msg);
    }
}
