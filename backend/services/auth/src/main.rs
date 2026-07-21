//! `saarathi-auth` — phone-OTP authentication service (Phase 0 skeleton).
//!
//! Endpoints are stubs for now; the real OTP issuance/verification, JWT minting,
//! and rate limiting come next. This binary exists so the workspace builds and
//! runs end-to-end from day one (vertical-slice discipline).

use axum::{routing::get, routing::post, Json, Router};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;

#[derive(Serialize)]
struct Health {
    service: &'static str,
    status: &'static str,
    version: &'static str,
}

async fn health() -> Json<Health> {
    Json(Health {
        service: "saarathi-auth",
        status: "ok",
        version: env!("CARGO_PKG_VERSION"),
    })
}

#[derive(Deserialize)]
struct OtpRequest {
    phone: String,
}

#[derive(Serialize)]
struct OtpResponse {
    // TODO: issue and send a real OTP via the SMS aggregator; rate-limit per phone.
    sent: bool,
    phone: String,
}

async fn request_otp(Json(req): Json<OtpRequest>) -> Json<OtpResponse> {
    tracing::info!(phone = %req.phone, "otp requested (stub)");
    Json(OtpResponse {
        sent: true,
        phone: req.phone,
    })
}

fn app() -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/v1/auth/otp/request", post(request_otp))
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .init();

    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8081);
    let addr = SocketAddr::from(([0, 0, 0, 0], port));

    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("saarathi-auth listening on http://{addr}");
    axum::serve(listener, app()).await?;
    Ok(())
}
