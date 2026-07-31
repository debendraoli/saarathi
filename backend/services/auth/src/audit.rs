//! Append-only audit trail for privileged staff actions (DoTM defensibility).

use sqlx::PgPool;
use uuid::Uuid;

pub async fn record(
    db: &PgPool,
    actor: Uuid,
    action: &str,
    entity_type: &str,
    entity_id: Uuid,
    detail: serde_json::Value,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO audit_log (actor_user_id, action, entity_type, entity_id, detail) \
         VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(actor)
    .bind(action)
    .bind(entity_type)
    .bind(entity_id)
    .bind(detail)
    .execute(db)
    .await?;
    Ok(())
}
