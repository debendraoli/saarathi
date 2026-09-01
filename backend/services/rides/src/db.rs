//! Database pool + idempotent schema bootstrap.

use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use sqlx::PgPool;
use uuid::Uuid;

pub async fn connect(database_url: &str) -> anyhow::Result<PgPool> {
    let pool = saarathi_core::bootstrap::connect_pg(database_url).await?;
    Ok(pool)
}

pub async fn init_schema(pool: &PgPool) -> anyhow::Result<()> {
    sqlx::raw_sql(include_str!("schema.sql"))
        .execute(pool)
        .await?;
    Ok(())
}

/// One-time data migration off the subscription-pass model (see
/// `schema.sql`'s `subscription_passes` note and
/// `docs/research/13-revenue-and-monetization.md`). Any pass still `active`
/// gets a prorated refund of its unused portion credited into the driver's
/// credit balance, then is flipped to `migrated`. Idempotent: once no rows are
/// `active`, subsequent runs are a no-op — safe to call on every startup.
#[derive(sqlx::FromRow)]
struct ActivePass {
    id: Uuid,
    driver_id: Uuid,
    price: Decimal,
    starts_at: DateTime<Utc>,
    ends_at: DateTime<Utc>,
}

pub async fn migrate_off_subscriptions(pool: &PgPool) -> anyhow::Result<()> {
    let passes: Vec<ActivePass> = sqlx::query_as(
        "SELECT id, driver_id, price, starts_at, ends_at FROM subscription_passes WHERE status = 'active'",
    )
    .fetch_all(pool)
    .await?;
    if passes.is_empty() {
        return Ok(());
    }

    let count = passes.len();
    for p in passes {
        let mut tx = pool.begin().await?;
        let total_secs = (p.ends_at - p.starts_at).num_seconds().max(1);
        let remaining_secs = (p.ends_at - Utc::now()).num_seconds().max(0);
        let refund =
            (p.price * Decimal::from(remaining_secs) / Decimal::from(total_secs)).round_dp(2);
        if refund > Decimal::ZERO {
            saarathi_core::wallet::credit_driver(
                &mut tx,
                p.driver_id,
                refund,
                "refund",
                Some("subscription-migration"),
            )
            .await?;
        }
        sqlx::query("UPDATE subscription_passes SET status = 'migrated', fair_cap_refund = $2 WHERE id = $1")
            .bind(p.id)
            .bind(refund)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
    }
    tracing::info!(
        count,
        "migrated drivers off subscription passes with prorated credit refunds"
    );
    Ok(())
}
