//! In-app notifications (E8). The inbox row is the durable record; for critical
//! classes we also escalate to push/SMS — mocked here behind the same call so the
//! real FCM/SMS providers drop in later (the "delivery ladder" from doc 09).

use crate::error::AppResult;
use sqlx::PgPool;
use uuid::Uuid;

pub async fn send(
    pool: &PgPool,
    user_id: Uuid,
    class: &str,
    title: &str,
    body: &str,
) -> AppResult<()> {
    sqlx::query("INSERT INTO notifications (user_id, class, title, body) VALUES ($1, $2, $3, $4)")
        .bind(user_id)
        .bind(class)
        .bind(title)
        .bind(body)
        .execute(pool)
        .await?;
    // Critical classes escalate past the inbox. Real push→SMS fallback lands here.
    if matches!(class, "safety" | "transactional" | "compliance") {
        tracing::info!(%user_id, class, title, "notification escalated (push/SMS mock)");
    }
    Ok(())
}
