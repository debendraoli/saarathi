//! Public auth endpoints: OTP request/verify, token refresh, logout.

use crate::error::{AppError, AppResult};
use crate::models::{User, UserRole};
use crate::otp;
use crate::state::AppState;
use crate::token;
use axum::extract::State;
use axum::{routing::post, Json, Router};
use chrono::{Duration, Utc};
use saarathi_core::api::ErrorCode;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/auth/otp/request", post(request_otp))
        .route("/v1/auth/otp/verify", post(verify_otp))
        .route("/v1/auth/refresh", post(refresh))
        .route("/v1/auth/logout", post(logout))
}

#[derive(Deserialize)]
struct OtpRequest {
    phone: String,
}

async fn request_otp(
    State(st): State<AppState>,
    Json(body): Json<OtpRequest>,
) -> AppResult<Json<Value>> {
    let phone = body.phone.trim().to_string();
    if !otp::valid_phone(&phone) {
        return Err(AppError::bad(
            ErrorCode::PhoneInvalid,
            "invalid phone number (use E.164, e.g. +9779800000000)",
        ));
    }

    // Rate limit by phone over the configured window.
    let since = Utc::now() - Duration::seconds(st.config.otp_rate_window_secs);
    let recent: i64 =
        sqlx::query_scalar("SELECT count(*) FROM otp_codes WHERE phone = $1 AND created_at > $2")
            .bind(&phone)
            .bind(since)
            .fetch_one(&st.db)
            .await?;
    if recent >= st.config.otp_rate_max {
        return Err(AppError::rate_limited(
            ErrorCode::OtpRateLimited,
            "too many OTP requests",
        ));
    }

    let code = otp::generate_code();
    let code_hash = otp::hash_code(&code).map_err(AppError::Other)?;
    let expires_at = Utc::now() + Duration::seconds(st.config.otp_ttl_secs);

    sqlx::query("INSERT INTO otp_codes (phone, code_hash, expires_at) VALUES ($1, $2, $3)")
        .bind(&phone)
        .bind(&code_hash)
        .bind(expires_at)
        .execute(&st.db)
        .await?;

    // TODO: dispatch via the SMS aggregator. In dev we log and echo the code.
    if st.config.otp_dev_mode {
        tracing::info!(%phone, %code, "OTP (dev mode)");
        return Ok(Json(json!({ "sent": true, "dev_code": code })));
    }
    tracing::info!(%phone, "OTP sent");
    Ok(Json(json!({ "sent": true })))
}

#[derive(Deserialize)]
struct VerifyRequest {
    phone: String,
    code: String,
    /// Optional: register as a driver instead of a rider on first login.
    #[serde(default)]
    as_driver: bool,
}

#[derive(Serialize)]
struct TokenPair {
    access_token: String,
    refresh_token: String,
    user: User,
}

async fn verify_otp(
    State(st): State<AppState>,
    Json(body): Json<VerifyRequest>,
) -> AppResult<Json<TokenPair>> {
    let phone = body.phone.trim().to_string();

    let row: Option<(Uuid, String, i32)> = sqlx::query_as(
        "SELECT id, code_hash, attempts FROM otp_codes \
         WHERE phone = $1 AND consumed_at IS NULL AND expires_at > now() \
         ORDER BY created_at DESC LIMIT 1",
    )
    .bind(&phone)
    .fetch_optional(&st.db)
    .await?;

    let (otp_id, code_hash, attempts) = row
        .ok_or_else(|| AppError::unauthorized(ErrorCode::OtpInvalid, "invalid or expired code"))?;
    if attempts >= 5 {
        return Err(AppError::rate_limited(
            ErrorCode::OtpRateLimited,
            "too many attempts",
        ));
    }

    if !otp::verify_code(&body.code, &code_hash) {
        sqlx::query("UPDATE otp_codes SET attempts = attempts + 1 WHERE id = $1")
            .bind(otp_id)
            .execute(&st.db)
            .await?;
        return Err(AppError::unauthorized(
            ErrorCode::OtpInvalid,
            "invalid or expired code",
        ));
    }

    sqlx::query("UPDATE otp_codes SET consumed_at = now() WHERE id = $1")
        .bind(otp_id)
        .execute(&st.db)
        .await?;

    // Upsert the user by phone. Never downgrade an existing (e.g. staff) role.
    let default_role = if body.as_driver {
        UserRole::Driver
    } else {
        UserRole::Rider
    };
    let user: User = sqlx::query_as(
        "INSERT INTO users (phone, role) VALUES ($1, $2) \
         ON CONFLICT (phone) DO UPDATE SET updated_at = now() \
         RETURNING id, phone, full_name, role, status, created_at, updated_at",
    )
    .bind(&phone)
    .bind(default_role)
    .fetch_one(&st.db)
    .await?;

    let pair = issue_tokens(&st, &user).await?;
    Ok(Json(pair))
}

#[derive(Deserialize)]
struct RefreshRequest {
    refresh_token: String,
}

async fn refresh(
    State(st): State<AppState>,
    Json(body): Json<RefreshRequest>,
) -> AppResult<Json<TokenPair>> {
    let hash = token::hash_token(&body.refresh_token);

    let row: Option<(Uuid, Uuid)> = sqlx::query_as(
        "SELECT id, user_id FROM refresh_tokens \
         WHERE token_hash = $1 AND revoked_at IS NULL AND expires_at > now()",
    )
    .bind(&hash)
    .fetch_optional(&st.db)
    .await?;
    let (token_id, user_id) = row.ok_or(AppError::Unauthorized)?;

    // Rotate: revoke the presented token, then issue a fresh pair.
    sqlx::query("UPDATE refresh_tokens SET revoked_at = now() WHERE id = $1")
        .bind(token_id)
        .execute(&st.db)
        .await?;

    let user: User = sqlx::query_as(
        "SELECT id, phone, full_name, role, status, created_at, updated_at FROM users WHERE id = $1",
    )
    .bind(user_id)
    .fetch_one(&st.db)
    .await?;

    let pair = issue_tokens(&st, &user).await?;
    Ok(Json(pair))
}

async fn logout(
    State(st): State<AppState>,
    Json(body): Json<RefreshRequest>,
) -> AppResult<Json<Value>> {
    let hash = token::hash_token(&body.refresh_token);
    sqlx::query(
        "UPDATE refresh_tokens SET revoked_at = now() WHERE token_hash = $1 AND revoked_at IS NULL",
    )
    .bind(&hash)
    .execute(&st.db)
    .await?;
    Ok(Json(json!({ "ok": true })))
}

async fn issue_tokens(st: &AppState, user: &User) -> AppResult<TokenPair> {
    let access = token::issue_access(
        &st.config.jwt_secret,
        user.id,
        user.role,
        st.config.access_ttl_secs,
    )
    .map_err(AppError::Other)?;
    let refresh = token::generate_refresh_token();
    let refresh_hash = token::hash_token(&refresh);
    let expires_at = Utc::now() + Duration::seconds(st.config.refresh_ttl_secs);

    sqlx::query("INSERT INTO refresh_tokens (user_id, token_hash, expires_at) VALUES ($1, $2, $3)")
        .bind(user.id)
        .bind(&refresh_hash)
        .bind(expires_at)
        .execute(&st.db)
        .await?;

    Ok(TokenPair {
        access_token: access,
        refresh_token: refresh,
        user: user.clone(),
    })
}
