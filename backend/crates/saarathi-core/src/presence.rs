//! Cross-service "is this user reachable in-app right now" registry.
//!
//! Backed by a Redis key per user with a short TTL, so a killed app or a
//! crashed connection self-heals without an explicit disconnect handler —
//! the key just expires. Written by whichever service holds a live
//! WebSocket to the user (currently `rides`'s trip-room and driver-scoped
//! sockets); read by `notify` before paying for a push/SMS send, so an
//! actively-connected user gets the in-app inbox row (always written,
//! unconditionally) without a redundant tray notification or text.

use uuid::Uuid;

fn key(user_id: Uuid) -> String {
    format!("presence:{user_id}")
}

/// How long a presence mark lasts without being refreshed. Comfortably
/// longer than any heartbeat interval callers use, so a connection that's
/// still open never flickers offline between refreshes.
const TTL_SECS: u64 = 45;

/// Mark a user reachable in-app. Call on socket connect and periodically
/// (well under `TTL_SECS`) while the socket stays open.
pub async fn mark_online(conn: &mut redis::aio::ConnectionManager, user_id: Uuid) {
    let res: redis::RedisResult<()> = redis::cmd("SET")
        .arg(key(user_id))
        .arg(1)
        .arg("EX")
        .arg(TTL_SECS)
        .query_async(conn)
        .await;
    if let Err(e) = res {
        tracing::warn!(error = %e, %user_id, "presence: mark_online failed");
    }
}

/// Clear a user's presence mark. Best-effort — call on clean socket close;
/// an abrupt drop is still covered by the TTL either way.
pub async fn mark_offline(conn: &mut redis::aio::ConnectionManager, user_id: Uuid) {
    let res: redis::RedisResult<()> = redis::cmd("DEL")
        .arg(key(user_id))
        .query_async(conn)
        .await;
    if let Err(e) = res {
        tracing::warn!(error = %e, %user_id, "presence: mark_offline failed");
    }
}

/// Whether a user currently has a live in-app connection anywhere.
/// Defaults to `false` (i.e. "send the push") on a Redis error — a presence
/// check failure must never silently swallow a notification.
pub async fn is_online(conn: &mut redis::aio::ConnectionManager, user_id: Uuid) -> bool {
    redis::cmd("EXISTS")
        .arg(key(user_id))
        .query_async::<i64>(conn)
        .await
        .map(|n| n > 0)
        .unwrap_or(false)
}
