//! `saarathi-auth` — identity, KYC, and location service.
//!
//! Phase 0: real phone-OTP auth (JWT + rotating refresh tokens), driver
//! registration with document upload, staff-driven KYC verification, and
//! PostGIS-backed rider/driver location data. See ../../../AGENTS.md.

mod audit;
mod config;
mod db;
mod error;
mod models;
mod otp;
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
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let config = Config::from_env()?;
    store::ensure_dir(&config.kyc_storage_dir)?;

    let pool = db::connect(&config.database_url).await?;
    db::init_schema(&pool).await?;

    if let Some(phone) = &config.seed_dev_admin_phone {
        seed_dev_admin(&pool, phone).await?;
    }

    let docs = Arc::new(LocalDocumentStore::new(&config.kyc_storage_dir));
    let port = config.port;
    let state = AppState {
        db: pool,
        config: Arc::new(config),
        docs,
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
