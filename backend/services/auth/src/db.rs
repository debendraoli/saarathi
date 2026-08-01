//! Database pool + idempotent schema bootstrap.

use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use std::time::Duration;

pub async fn connect(database_url: &str) -> anyhow::Result<PgPool> {
    let pool = PgPoolOptions::new()
        .max_connections(10)
        .acquire_timeout(Duration::from_secs(5))
        .connect(database_url)
        .await?;
    Ok(pool)
}

/// Provision the schema idempotently from a single embedded source of truth.
/// There are no migration files — a fresh database is brought fully up to date
/// by running `schema.sql` (guarded with IF NOT EXISTS so restarts are safe).
pub async fn init_schema(pool: &PgPool) -> anyhow::Result<()> {
    sqlx::raw_sql(include_str!("schema.sql"))
        .execute(pool)
        .await?;
    Ok(())
}
