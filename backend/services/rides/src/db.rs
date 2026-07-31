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

pub async fn init_schema(pool: &PgPool) -> anyhow::Result<()> {
    sqlx::raw_sql(include_str!("schema.sql")).execute(pool).await?;
    Ok(())
}
