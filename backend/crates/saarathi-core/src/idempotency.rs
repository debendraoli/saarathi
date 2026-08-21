//! Idempotency-key enforcement for client-initiated money-moving requests
//! (top-up, withdrawal) — persisted in Postgres, not in-memory, so replay
//! protection survives pod restarts. Both `saarathi-payments` and
//! `saarathi-rides` call this against the shared `idempotency_keys` table.
//!
//! Protocol: [`reserve`] claims `(key, user_id, endpoint)` *before* the
//! handler does any work, so a second request racing in with the same key
//! finds the reservation already taken and never re-executes the mutation.
//! On success the handler calls [`store`] to record the response for replay.
//! If the handler errors out before calling `store`, the reservation is left
//! with no response — a genuine retry after a failed attempt should use a
//! fresh key rather than reuse one that never completed.

use serde_json::Value;
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

#[derive(Debug, thiserror::Error)]
pub enum IdempotencyError {
    #[error("a request with this idempotency key is already in flight or previously failed")]
    InFlight,
    #[error(transparent)]
    Db(#[from] sqlx::Error),
}

pub enum Reservation {
    /// First time this key has been seen for this user+endpoint — proceed.
    New,
    /// Already completed — replay this stored response instead of redoing the work.
    Replay { status: i16, body: Value },
}

/// Claim `key` for `user_id`+`endpoint`, inside the caller's transaction so the
/// claim and the money mutation commit together. Must run at the very start
/// of the handler, before any balance mutation.
pub async fn reserve(
    tx: &mut Transaction<'_, Postgres>,
    key: &str,
    user_id: Uuid,
    endpoint: &str,
) -> Result<Reservation, IdempotencyError> {
    let inserted: Option<(Option<i16>, Option<Value>)> = sqlx::query_as(
        "INSERT INTO idempotency_keys (key, user_id, endpoint) VALUES ($1, $2, $3) \
         ON CONFLICT (key, user_id, endpoint) DO NOTHING \
         RETURNING status_code, response",
    )
    .bind(key)
    .bind(user_id)
    .bind(endpoint)
    .fetch_optional(&mut **tx)
    .await?;
    if inserted.is_some() {
        return Ok(Reservation::New);
    }

    let existing: Option<(Option<i16>, Option<Value>)> = sqlx::query_as(
        "SELECT status_code, response FROM idempotency_keys \
         WHERE key = $1 AND user_id = $2 AND endpoint = $3",
    )
    .bind(key)
    .bind(user_id)
    .bind(endpoint)
    .fetch_optional(&mut **tx)
    .await?;
    match existing {
        Some((Some(status), Some(body))) => Ok(Reservation::Replay { status, body }),
        _ => Err(IdempotencyError::InFlight),
    }
}

/// Record the final response so a retry with the same key replays it instead
/// of re-executing. Call only after the mutation has succeeded.
pub async fn store(
    tx: &mut Transaction<'_, Postgres>,
    key: &str,
    user_id: Uuid,
    endpoint: &str,
    status: u16,
    body: &Value,
) -> Result<(), IdempotencyError> {
    sqlx::query(
        "UPDATE idempotency_keys SET status_code = $4, response = $5 \
         WHERE key = $1 AND user_id = $2 AND endpoint = $3",
    )
    .bind(key)
    .bind(user_id)
    .bind(endpoint)
    .bind(status as i16)
    .bind(body)
    .execute(&mut **tx)
    .await?;
    Ok(())
}
