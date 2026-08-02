//! Partner-scoped audit trail (writes the shared `audit_log`, owned by auth).

use crate::error::AppResult;
use serde_json::Value;
use uuid::Uuid;

/// Record a governance action (platform admin acting on a partner).
pub async fn record(
    db: &sqlx::PgPool,
    actor: Uuid,
    action: &str,
    entity_type: &str,
    entity_id: Uuid,
    payload: Value,
) -> AppResult<()> {
    sqlx::query(
        "INSERT INTO audit_log (actor_user_id, action, entity_type, entity_id, detail) \
         VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(actor)
    .bind(action)
    .bind(entity_type)
    .bind(entity_id)
    .bind(payload)
    .execute(db)
    .await?;
    Ok(())
}

/// Record a partner-scoped action (records the acting partner on the row).
pub async fn partner(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    actor: Uuid,
    partner_id: Uuid,
    action: &str,
    entity_id: Uuid,
) -> AppResult<()> {
    sqlx::query(
        "INSERT INTO audit_log (actor_user_id, action, entity_type, entity_id, partner_id) \
         VALUES ($1, $2, 'partner', $3, $4)",
    )
    .bind(actor)
    .bind(action)
    .bind(entity_id)
    .bind(partner_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}
