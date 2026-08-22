//! Runtime configuration for saarathi-places.

use anyhow::Context;

#[derive(Debug, Clone)]
pub struct Config {
    pub database_url: String,
    pub port: u16,
    pub jwt_secret: String,
    /// Where proof photos live on disk (dev only — see `store.rs`).
    pub places_storage_dir: String,
    pub nats_url: String,
}

impl Config {
    pub fn from_env() -> anyhow::Result<Self> {
        Ok(Config {
            database_url: req("DATABASE_URL")?,
            port: opt("PLACES_PORT")
                .unwrap_or_else(|| "8089".into())
                .parse()
                .context("PLACES_PORT")?,
            jwt_secret: req("JWT_SECRET")?,
            places_storage_dir: opt("PLACES_STORAGE_DIR").unwrap_or_else(|| "./.data/places".into()),
            nats_url: opt("NATS_URL").unwrap_or_else(|| "nats://localhost:4222".into()),
        })
    }
}

fn req(key: &str) -> anyhow::Result<String> {
    std::env::var(key).with_context(|| format!("missing required env var {key}"))
}

fn opt(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.is_empty())
}
