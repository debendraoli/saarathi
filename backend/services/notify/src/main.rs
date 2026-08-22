//! `saarathi-notify` — the notification service.
//!
//! It owns the in-app inbox and the push/SMS "delivery ladder". Other services
//! don't write notifications directly; they publish a `NotifyRequest` to NATS
//! ([`saarathi_core::events::NOTIFY_SUBJECT`]) and this service consumes it,
//! persists the durable inbox row, and escalates critical classes. Fully
//! decoupled from the trip transaction — a natural first microservice split.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::{DateTime, Utc};
use futures_util::StreamExt;
use saarathi_core::authn::{AuthUser, HasJwtSecret};
use saarathi_core::domain::notif;
use saarathi_core::events::{NotifyRequest, NOTIFY_SUBJECT};
use serde::Serialize;
use serde_json::{json, Value};
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use std::sync::Arc;
use std::time::Duration;
use tower_http::{catch_panic::CatchPanicLayer, trace::TraceLayer};
use uuid::Uuid;

mod fcm;
mod sms;

#[derive(Clone)]
struct AppState {
    db: PgPool,
    jwt_secret: Arc<String>,
}

impl HasJwtSecret for AppState {
    fn jwt_secret(&self) -> &str {
        &self.jwt_secret
    }
}

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key)
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| default.into())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let database_url = std::env::var("DATABASE_URL")?;
    let jwt_secret = std::env::var("JWT_SECRET")?;
    let nats_url = env_or("NATS_URL", "nats://localhost:4222");
    let port: u16 = env_or("NOTIFY_PORT", "8083").parse()?;

    let pool = PgPoolOptions::new()
        .max_connections(10)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&database_url)
        .await?;
    sqlx::raw_sql(include_str!("schema.sql"))
        .execute(&pool)
        .await?;

    // Consume notification requests off the bus. If NATS is down we still serve
    // the (read-only) inbox — delivery resumes when the bus returns.
    let fcm = fcm::FcmSender::from_env();
    let sms = sms::SmsSender::from_env().map(Arc::new);
    match async_nats::connect(&nats_url).await {
        Ok(client) => {
            tokio::spawn(consume(client, pool.clone(), fcm.clone(), sms.clone()));
            tracing::info!(%nats_url, "notify: subscribed to {NOTIFY_SUBJECT}");
        }
        Err(e) => tracing::warn!(error = %e, "notify: NATS unavailable; inbox is read-only"),
    }

    let state = AppState {
        db: pool,
        jwt_secret: Arc::new(jwt_secret),
    };
    let app = Router::new()
        .route("/health", get(health))
        .route("/v1/notifications", get(inbox))
        .route("/v1/notifications/{id}/read", post(mark_read))
        .route("/v1/notifications/read-all", post(read_all))
        .layer(CatchPanicLayer::new())
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let addr = std::net::SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("saarathi-notify listening on http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}

/// NATS consumer loop: durable inbox row + push/SMS escalation for critical classes.
async fn consume(
    client: async_nats::Client,
    pool: PgPool,
    fcm: Option<Arc<fcm::FcmSender>>,
    sms: Option<Arc<sms::SmsSender>>,
) {
    let mut sub = match client.subscribe(NOTIFY_SUBJECT).await {
        Ok(s) => s,
        Err(e) => {
            tracing::error!(error = %e, "notify: failed to subscribe");
            return;
        }
    };
    while let Some(msg) = sub.next().await {
        match serde_json::from_slice::<NotifyRequest>(&msg.payload) {
            Ok(req) => {
                if let Err(e) = deliver(&pool, &req, fcm.as_deref(), sms.as_deref()).await {
                    tracing::warn!(error = %e, "notify: delivery failed");
                }
            }
            Err(e) => tracing::warn!(error = %e, "notify: bad NotifyRequest payload"),
        }
    }
}

async fn deliver(
    pool: &PgPool,
    req: &NotifyRequest,
    fcm: Option<&fcm::FcmSender>,
    sms: Option<&sms::SmsSender>,
) -> anyhow::Result<()> {
    sqlx::query(
        "INSERT INTO notifications (user_id, class, title, body, link) VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(req.user_id)
    .bind(&req.class)
    .bind(&req.title)
    .bind(&req.body)
    .bind(&req.link)
    .execute(pool)
    .await?;

    // Fan out to the user's registered devices via FCM (when configured). A
    // stale token (FCM UNREGISTERED) is pruned on the spot — no point paying
    // for it on every future notification, and it'd otherwise sit forever
    // since nothing else ever revisits `device_tokens`.
    let mut any_push_sent = false;
    if let Some(sender) = fcm {
        let tokens: Vec<(String,)> =
            sqlx::query_as("SELECT token FROM device_tokens WHERE user_id = $1")
                .bind(req.user_id)
                .fetch_all(pool)
                .await
                .unwrap_or_default();
        for (token,) in tokens {
            match sender
                .send(&token, &req.title, &req.body, req.link.as_deref())
                .await
            {
                Ok(()) => any_push_sent = true,
                Err(fcm::SendError::StaleToken) => {
                    let _ = sqlx::query("DELETE FROM device_tokens WHERE token = $1")
                        .bind(&token)
                        .execute(pool)
                        .await;
                    tracing::info!(%token, "notify: pruned stale FCM token");
                }
                Err(fcm::SendError::Other(e)) => {
                    tracing::warn!(error = %e, "notify: FCM send failed");
                }
            }
        }
    }

    // Critical classes (safety/transactional/compliance) fall back to SMS
    // when push didn't land — no registered device, every token was stale,
    // or FCM isn't configured on this deployment. Not for every class: a
    // marketing notification with no push is just... not delivered, which
    // is fine.
    if notif::CRITICAL.contains(&req.class.as_str()) && !any_push_sent {
        if let Some(sender) = sms {
            let phone: Option<String> =
                sqlx::query_scalar("SELECT phone FROM users WHERE id = $1")
                    .bind(req.user_id)
                    .fetch_optional(pool)
                    .await
                    .ok()
                    .flatten();
            if let Some(phone) = phone {
                if let Err(e) = sender.send(&phone, &req.title, &req.body).await {
                    tracing::warn!(error = %e, "notify: SMS fallback failed");
                } else {
                    tracing::info!(user_id = %req.user_id, class = %req.class,
                        "notify: critical notification escalated to SMS (push unreachable)");
                }
            }
        }
    }
    Ok(())
}

async fn health() -> Json<Value> {
    Json(json!({ "service": "saarathi-notify", "status": "ok" }))
}

#[derive(Serialize, sqlx::FromRow)]
struct Notification {
    id: Uuid,
    class: String,
    title: String,
    body: Option<String>,
    link: Option<String>,
    read_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
}

async fn inbox(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> Result<Json<Value>, StatusCode> {
    let items: Vec<Notification> = sqlx::query_as(
        "SELECT id, class, title, body, link, read_at, created_at FROM notifications \
         WHERE user_id = $1 ORDER BY created_at DESC LIMIT 100",
    )
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await
    .map_err(internal)?;
    let unread = items.iter().filter(|n| n.read_at.is_none()).count();
    Ok(Json(json!({ "unread": unread, "items": items })))
}

async fn mark_read(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> Result<Json<Value>, StatusCode> {
    let res = sqlx::query(
        "UPDATE notifications SET read_at = now() WHERE id = $1 AND user_id = $2 AND read_at IS NULL",
    )
    .bind(id)
    .bind(claims.sub)
    .execute(&st.db)
    .await
    .map_err(internal)?;
    if res.rows_affected() == 0 {
        return Err(StatusCode::NOT_FOUND);
    }
    Ok(Json(json!({ "ok": true })))
}

async fn read_all(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> Result<Json<Value>, StatusCode> {
    let res = sqlx::query(
        "UPDATE notifications SET read_at = now() WHERE user_id = $1 AND read_at IS NULL",
    )
    .bind(claims.sub)
    .execute(&st.db)
    .await
    .map_err(internal)?;
    Ok(Json(json!({ "marked": res.rows_affected() })))
}

fn internal(e: sqlx::Error) -> StatusCode {
    tracing::error!(error = ?e, "notify: db error");
    StatusCode::INTERNAL_SERVER_ERROR
}
