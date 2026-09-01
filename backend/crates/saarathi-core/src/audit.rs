//! `audit_log` writer, shared by every service that isn't `auth` (which has
//! its own richer `audit` module — this covers the small, identical
//! `INSERT INTO audit_log` helper that `rides` and `merchant` each carried
//! a local copy of, per AGENTS.md's "every staff mutation is audit-logged"
//! rule.

use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

/// Appends one row to the shared `audit_log` table.
pub async fn record(
    db: &PgPool,
    actor: Uuid,
    action: &str,
    entity_type: &str,
    entity_id: Uuid,
    detail: Value,
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
