//! `saarathi-auth` — identity, KYC, and location service.
//!
//! Phase 0: real phone-OTP auth (JWT + rotating refresh tokens), driver
//! registration with document upload, staff-driven KYC verification, and
//! PostGIS-backed rider/driver location data. See ../../../AGENTS.md.

mod audit;
mod auth;
mod config;
mod db;
mod error;
mod models;
mod notify;
mod otp;
mod otp_delivery;
mod rate_limit;
mod routes;
mod state;
mod store;
mod token;

use config::Config;
use state::AppState;
use std::sync::Arc;
use store::LocalDocumentStore;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    saarathi_core::bootstrap::init_tracing();

    let config = Config::from_env()?;
    store::ensure_dir(&config.kyc_storage_dir)?;

    let pool = saarathi_core::bootstrap::connect_pg(&config.database_url).await?;
    db::init_schema(&pool).await?;

    if let Some(phone) = &config.seed_dev_admin_phone {
        seed_dev_admin(&pool, phone).await?;
    }

    let redis = match redis::Client::open(config.redis_url.clone()) {
        Ok(client) => match redis::aio::ConnectionManager::new(client).await {
            Ok(cm) => Some(cm),
            Err(e) => {
                tracing::warn!(error = %e, "redis unavailable; OTP rate limiter will fail open");
                None
            }
        },
        Err(e) => {
            tracing::warn!(error = %e, "invalid REDIS_URL; OTP rate limiter will fail open");
            None
        }
    };
    let otp_delivery = Arc::new(otp_delivery::OtpDelivery::new(
        config.whatsapp.clone(),
        config.sparrow.clone(),
    ));

    // NATS bus for KYC-decision notifications (non-fatal: approvals still
    // work if the bus is down, the applicant just doesn't get told).
    let nats = match async_nats::connect(&config.nats_url).await {
        Ok(c) => Some(c),
        Err(e) => {
            tracing::warn!(error = %e, "NATS unavailable; KYC notifications will be skipped");
            None
        }
    };

    let docs = Arc::new(LocalDocumentStore::new(&config.kyc_storage_dir));
    let port = config.port;
    let state = AppState {
        db: pool,
        config: Arc::new(config),
        docs,
        redis,
        otp_delivery,
        nats,
    };

    let app = routes::router(state);
    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("saarathi-auth listening on http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}

/// Dev convenience: ensure a super-admin exists so the dashboard can be tested.
async fn seed_dev_admin(pool: &sqlx::PgPool, phone: &str) -> anyhow::Result<()> {
    sqlx::query(
        "INSERT INTO users (phone, full_name, role, status) VALUES ($1, 'Dev Admin', 'super_admin', 'active') \
         ON CONFLICT (phone) DO UPDATE SET role = 'super_admin', status = 'active'",
    )
    .bind(phone)
    .execute(pool)
    .await?;
    tracing::warn!(%phone, "seeded dev super-admin (disable SEED_DEV_ADMIN_PHONE in production)");
    Ok(())
}
