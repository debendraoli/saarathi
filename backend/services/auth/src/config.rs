//! Runtime configuration, loaded from the environment (`.env` in dev).

use anyhow::Context;

#[derive(Debug, Clone)]
pub struct Config {
    pub database_url: String,
    pub port: u16,
    pub jwt_secret: String,
    pub access_ttl_secs: i64,
    pub refresh_ttl_secs: i64,
    pub otp_ttl_secs: i64,
    pub otp_rate_max: i64,
    pub otp_rate_window_secs: i64,
    /// When true, OTP codes are logged and returned in the API response so the
    /// dashboard/apps can be tested without a live SMS gateway. Never in prod.
    pub otp_dev_mode: bool,
    pub kyc_storage_dir: String,
    /// Optionally upsert a dev super-admin on boot (for local dashboard testing).
    pub seed_dev_admin_phone: Option<String>,
}

impl Config {
    pub fn from_env() -> anyhow::Result<Self> {
        Ok(Config {
            database_url: req("DATABASE_URL")?,
            port: opt("PORT")
                .unwrap_or_else(|| "8081".into())
                .parse()
                .context("PORT")?,
            jwt_secret: req("JWT_SECRET")?,
            access_ttl_secs: opt_parse("JWT_ACCESS_TTL_SECS", 900),
            refresh_ttl_secs: opt_parse("JWT_REFRESH_TTL_DAYS", 30) * 86_400,
            otp_ttl_secs: opt_parse("OTP_TTL_SECS", 300),
            otp_rate_max: opt_parse("OTP_RATE_MAX", 5),
            otp_rate_window_secs: opt_parse("OTP_RATE_WINDOW_SECS", 3_600),
            otp_dev_mode: flag("OTP_DEV_MODE"),
            kyc_storage_dir: opt("KYC_STORAGE_DIR").unwrap_or_else(|| "./.data/kyc".into()),
            seed_dev_admin_phone: opt("SEED_DEV_ADMIN_PHONE"),
        })
    }
}

fn req(key: &str) -> anyhow::Result<String> {
    std::env::var(key).with_context(|| format!("missing required env var {key}"))
}

fn opt(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.is_empty())
}

fn opt_parse<T: std::str::FromStr>(key: &str, default: T) -> T {
    opt(key).and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn flag(key: &str) -> bool {
    matches!(opt(key).as_deref(), Some("1") | Some("true") | Some("TRUE"))
}
