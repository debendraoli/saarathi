//! Rider/driver support chat — a plain, persisted, one-thread-per-user
//! conversation with staff. Deliberately simple (poll, not a WS channel):
//! same "5s poll is enough" call the SOS console already makes in
//! `safety.rs`'s doc comment, and support replies aren't time-critical the
//! way a live trip location is.

use crate::auth::{AuthUser, StaffUser};
use crate::error::{AppError, AppResult};
use crate::notify;
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{routing::get, Json, Router};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/support/messages", get(my_thread).post(send_message))
        .route("/v1/admin/support/threads", get(list_threads))
        .route(
            "/v1/admin/support/threads/{user_id}/messages",
            get(staff_thread).post(staff_reply),
        )
}

#[derive(Serialize, sqlx::FromRow)]
struct SupportMessage {
    id: Uuid,
    sender_role: String, // user | staff
    body: String,
    trip_id: Option<Uuid>,
    order_id: Option<Uuid>,
    created_at: DateTime<Utc>,
}

/// A referenced trip must actually belong to the sender (rider, driver, or
/// — for a delivery — the fulfilling merchant) — same participant rule
/// `ws.rs::is_participant` uses for the trip-room socket, just without a
/// staff exemption (staff replies never validate a reference; see
/// `staff_reply`).
async fn validate_trip_ref(st: &AppState, uid: Uuid, trip_id: Uuid) -> AppResult<()> {
    let row: Option<(Uuid, Option<Uuid>, String)> =
        sqlx::query_as("SELECT rider_id, driver_id, trip_type::text FROM trips WHERE id = $1")
            .bind(trip_id)
            .fetch_optional(&st.db)
            .await?;
    let Some((rider, driver, trip_type)) = row else {
        return Err(AppError::BadRequest("referenced trip not found".into()));
    };
    if rider == uid || driver == Some(uid) {
        return Ok(());
    }
    if trip_type == "delivery" {
        let owns: Option<Uuid> = sqlx::query_scalar(
            "SELECT m.id FROM orders o JOIN merchants m ON m.id = o.merchant_id \
             WHERE o.trip_id = $1 AND m.owner_user_id = $2",
        )
        .bind(trip_id)
        .bind(uid)
        .fetch_optional(&st.db)
        .await?;
        if owns.is_some() {
            return Ok(());
        }
    }
    Err(AppError::Forbidden)
}

/// Same idea for a referenced order: the customer who placed it, or the
/// owner of the merchant fulfilling it.
async fn validate_order_ref(st: &AppState, uid: Uuid, order_id: Uuid) -> AppResult<()> {
    let row: Option<(Uuid, Uuid)> =
        sqlx::query_as("SELECT customer_id, merchant_id FROM orders WHERE id = $1")
            .bind(order_id)
            .fetch_optional(&st.db)
            .await?;
    let Some((customer_id, merchant_id)) = row else {
        return Err(AppError::BadRequest("referenced order not found".into()));
    };
    if customer_id == uid {
        return Ok(());
    }
    let owns: Option<Uuid> =
        sqlx::query_scalar("SELECT id FROM merchants WHERE id = $1 AND owner_user_id = $2")
            .bind(merchant_id)
            .bind(uid)
            .fetch_optional(&st.db)
            .await?;
    if owns.is_some() {
        return Ok(());
    }
    Err(AppError::Forbidden)
}

async fn my_thread(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Vec<SupportMessage>>> {
    let rows: Vec<SupportMessage> = sqlx::query_as(
        "SELECT id, sender_role, body, trip_id, order_id, created_at FROM support_messages \
         WHERE user_id = $1 ORDER BY created_at ASC",
    )
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;
    sqlx::query("UPDATE support_messages SET read_by_user = true WHERE user_id = $1 AND read_by_user = false")
        .bind(claims.sub)
        .execute(&st.db)
        .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
struct NewMessage {
    body: String,
    trip_id: Option<Uuid>,
    order_id: Option<Uuid>,
}

async fn send_message(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(b): Json<NewMessage>,
) -> AppResult<Json<SupportMessage>> {
    let body = b.body.trim();
    if body.is_empty() {
        return Err(AppError::BadRequest("message body is required".into()));
    }
    if let Some(trip_id) = b.trip_id {
        validate_trip_ref(&st, claims.sub, trip_id).await?;
    }
    if let Some(order_id) = b.order_id {
        validate_order_ref(&st, claims.sub, order_id).await?;
    }
    let row: SupportMessage = sqlx::query_as(
        "INSERT INTO support_messages (user_id, sender_id, sender_role, body, trip_id, order_id) \
         VALUES ($1, $1, 'user', $2, $3, $4) \
         RETURNING id, sender_role, body, trip_id, order_id, created_at",
    )
    .bind(claims.sub)
    .bind(body)
    .bind(b.trip_id)
    .bind(b.order_id)
    .fetch_one(&st.db)
    .await?;

    let staff_ids: Vec<(Uuid,)> =
        sqlx::query_as("SELECT id FROM users WHERE role NOT IN ('rider', 'driver')")
            .fetch_all(&st.db)
            .await
            .unwrap_or_default();
    for (staff_id,) in staff_ids {
        notify::send(
            &st.nats,
            staff_id,
            saarathi_core::domain::notif::SUPPORT,
            "New support message",
            body,
            Some("/support".to_string()),
        )
        .await;
    }
    Ok(Json(row))
}

/// One row per rider/driver with at least one message — the newest message
/// and how many of theirs are still unread by staff, for the console's inbox
/// list. Ordered by most recently active, same convention as any inbox.
#[derive(Serialize, sqlx::FromRow)]
struct SupportThread {
    user_id: Uuid,
    user_name: Option<String>,
    user_phone: Option<String>,
    last_message: String,
    last_at: DateTime<Utc>,
    unread: i64,
    /// The most recent message's own reference, if it had one — a quick
    /// "what's this about" hint in the inbox list before staff even opens
    /// the thread. Not necessarily *every* message's reference (a thread
    /// can drift across several rides/orders over time); see each
    /// message's own `trip_id`/`order_id` for that.
    last_trip_id: Option<Uuid>,
    last_order_id: Option<Uuid>,
}

async fn list_threads(
    State(st): State<AppState>,
    _staff: StaffUser,
) -> AppResult<Json<Vec<SupportThread>>> {
    let rows: Vec<SupportThread> = sqlx::query_as(
        "SELECT DISTINCT ON (m.user_id) \
                m.user_id, u.full_name AS user_name, u.phone AS user_phone, \
                m.body AS last_message, m.created_at AS last_at, \
                m.trip_id AS last_trip_id, m.order_id AS last_order_id, \
                (SELECT count(*) FROM support_messages um \
                   WHERE um.user_id = m.user_id AND um.sender_role = 'user' \
                     AND um.read_by_staff = false) AS unread \
         FROM support_messages m \
         JOIN users u ON u.id = m.user_id \
         ORDER BY m.user_id, m.created_at DESC",
    )
    .fetch_all(&st.db)
    .await?;
    let mut sorted = rows;
    sorted.sort_by(|a, b| b.last_at.cmp(&a.last_at));
    Ok(Json(sorted))
}

async fn staff_thread(
    State(st): State<AppState>,
    _staff: StaffUser,
    Path(user_id): Path<Uuid>,
) -> AppResult<Json<Vec<SupportMessage>>> {
    let rows: Vec<SupportMessage> = sqlx::query_as(
        "SELECT id, sender_role, body, trip_id, order_id, created_at FROM support_messages \
         WHERE user_id = $1 ORDER BY created_at ASC",
    )
    .bind(user_id)
    .fetch_all(&st.db)
    .await?;
    sqlx::query(
        "UPDATE support_messages SET read_by_staff = true \
         WHERE user_id = $1 AND read_by_staff = false",
    )
    .bind(user_id)
    .execute(&st.db)
    .await?;
    Ok(Json(rows))
}

async fn staff_reply(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Path(user_id): Path<Uuid>,
    Json(b): Json<NewMessage>,
) -> AppResult<Json<SupportMessage>> {
    let body = b.body.trim();
    if body.is_empty() {
        return Err(AppError::BadRequest("message body is required".into()));
    }
    let row: SupportMessage = sqlx::query_as(
        "INSERT INTO support_messages (user_id, sender_id, sender_role, body, trip_id, order_id, read_by_staff) \
         VALUES ($1, $2, 'staff', $3, $4, $5, true) \
         RETURNING id, sender_role, body, trip_id, order_id, created_at",
    )
    .bind(user_id)
    .bind(claims.sub)
    .bind(body)
    .bind(b.trip_id)
    .bind(b.order_id)
    .fetch_one(&st.db)
    .await?;

    notify::send(
        &st.nats,
        user_id,
        saarathi_core::domain::notif::SUPPORT,
        "Reply from Saarathi support",
        body,
        Some("saarathi://support".to_string()),
    )
    .await;
    Ok(Json(row))
}
