//! Database schema bootstrap (pool creation lives in
//! `saarathi_core::bootstrap::connect_pg`).

use sqlx::PgPool;

/// Provision the schema idempotently from a single embedded source of truth.
/// There are no migration files — a fresh database is brought fully up to date
/// by running `schema.sql` (guarded with IF NOT EXISTS so restarts are safe).
pub async fn init_schema(pool: &PgPool) -> anyhow::Result<()> {
    sqlx::raw_sql(include_str!("schema.sql"))
        .execute(pool)
        .await?;
    Ok(())
}
