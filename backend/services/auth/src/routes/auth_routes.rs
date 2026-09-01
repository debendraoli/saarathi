//! Public auth endpoints: OTP request/verify, token refresh, logout.

use crate::error::{AppError, AppResult};
use crate::models::{User, UserRole, UserStatus};
use crate::otp;
use crate::rate_limit;
use crate::state::AppState;
use crate::token;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::{Json, Router, routing::post};
use chrono::{Duration, Utc};
use saarathi_core::api::ErrorCode;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

/// Best-effort client IP for rate-limit keying. Traefik (this platform's one
/// front door — see `AGENTS.md`) *appends* to `X-Forwarded-For`, so with
/// exactly one trusted hop in front of this service, the trustworthy entry
/// is the **last** one — Traefik's own view of the peer. The first entry is
/// whatever the client itself sent and is trivially spoofable (a caller
/// could set it to dodge their own rate limit), so it must never be trusted.
/// Falls back to a constant so direct/dev access (no proxy in front) still
/// rate-limits, just by phone alone in that case.
fn client_ip(headers: &HeaderMap) -> String {
    headers
        .get("x-forwarded-for")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.split(',').next_back())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".to_string())
}

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
    headers: HeaderMap,
    Json(body): Json<OtpRequest>,
) -> AppResult<Json<Value>> {
    let phone = body.phone.trim().to_string();
    if !otp::valid_phone(&phone) {
        return Err(AppError::bad(
            ErrorCode::PhoneInvalid,
            "invalid phone number (use E.164, e.g. +9779800000000)",
        ));
    }

    // Coarser, longer-window limit (DB-based, phone-only) — the existing check.
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

    // Tighter burst limit: 3 requests / 10 min, keyed by both IP and phone —
    // either bucket running dry blocks the request (see `crate::rate_limit`).
    if let Some(mut redis) = st.redis.clone() {
        let ip = client_ip(&headers);
        if !rate_limit::check(
            &mut redis,
            &ip,
            &phone,
            &st.config.otp_rate_limit_ip_allowlist,
        )
        .await
        {
            return Err(AppError::rate_limited(
                ErrorCode::OtpRateLimited,
                "too many OTP requests — please wait a few minutes",
            ));
        }
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

    if st.config.otp_dev_mode {
        tracing::info!(%phone, %code, "OTP (dev mode)");
        return Ok(Json(json!({ "sent": true, "dev_code": code })));
    }
    match st.otp_delivery.send(&phone, &code).await {
        Ok(channel) => {
            tracing::info!(%phone, ?channel, "OTP sent");
            Ok(Json(json!({ "sent": true, "channel": channel })))
        }
        Err(e) => {
            tracing::error!(%phone, error = %e, "OTP delivery failed on every channel");
            Err(AppError::Other(e))
        }
    }
}

#[derive(Deserialize)]
struct VerifyRequest {
    phone: String,
    code: String,
    /// Optional: register as a driver instead of a rider on first login.
    #[serde(default)]
    as_driver: bool,
    /// This install's persistent client-generated id — lets this login tell
    /// sibling sessions (other devices) apart from itself when enforcing
    /// single-device-per-account. Omitted by older app builds.
    #[serde(default)]
    device_id: Option<String>,
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

    if matches!(user.status, UserStatus::Suspended | UserStatus::Banned) {
        return Err(AppError::forbidden(
            ErrorCode::AccountSuspended,
            "this account has been suspended",
        ));
    }

    let (pair, new_token_id) = issue_tokens(&st, &user, body.device_id.as_deref()).await?;
    enforce_single_device(&st, user.id, new_token_id, body.device_id.as_deref()).await;
    Ok(Json(pair))
}

/// Single-device-per-account enforcement: revoke every other still-valid
/// session for this user, *except* — if they currently have an active
/// trip — the one other session most recently active (best available proxy
/// for "the device actually driving that trip"; nothing in the schema
/// links a trip to a specific device). Fires a silent push so an already-
/// foregrounded/backgrounded-but-alive sibling device signs out right away
/// instead of waiting for its access token to naturally expire.
async fn enforce_single_device(
    st: &AppState,
    user_id: Uuid,
    new_token_id: Uuid,
    new_device_id: Option<&str>,
) {
    // Cross-service read against rides' `trips` table — same shared-Postgres
    // convention already used elsewhere in this codebase.
    let has_active_trip: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM trips WHERE (rider_id = $1 OR driver_id = $1) \
         AND status NOT IN ('completed', 'cancelled'))",
    )
    .bind(user_id)
    .fetch_one(&st.db)
    .await
    .unwrap_or(false);

    let revoked: Vec<(Uuid,)> = if has_active_trip {
        sqlx::query_as(
            "WITH keep AS ( \
                SELECT id FROM refresh_tokens \
                WHERE user_id = $1 AND revoked_at IS NULL AND id <> $2 \
                ORDER BY created_at DESC LIMIT 1 \
             ) \
             UPDATE refresh_tokens SET revoked_at = now() \
             WHERE user_id = $1 AND revoked_at IS NULL AND id <> $2 \
               AND id NOT IN (SELECT id FROM keep) \
             RETURNING id",
        )
        .bind(user_id)
        .bind(new_token_id)
        .fetch_all(&st.db)
        .await
        .unwrap_or_default()
    } else {
        sqlx::query_as(
            "UPDATE refresh_tokens SET revoked_at = now() \
             WHERE user_id = $1 AND revoked_at IS NULL AND id <> $2 \
             RETURNING id",
        )
        .bind(user_id)
        .bind(new_token_id)
        .fetch_all(&st.db)
        .await
        .unwrap_or_default()
    };

    if revoked.is_empty() {
        return;
    }
    crate::notify::send_silent(
        &st.nats,
        user_id,
        json!({ "type": "force_logout", "new_device_id": new_device_id.unwrap_or("") }),
    )
    .await;
}

#[derive(Deserialize)]
struct RefreshRequest {
    refresh_token: String,
    #[serde(default)]
    device_id: Option<String>,
}

async fn refresh(
    State(st): State<AppState>,
    Json(body): Json<RefreshRequest>,
) -> AppResult<Json<TokenPair>> {
    let hash = token::hash_token(&body.refresh_token);

    let row: Option<(Uuid, Uuid, Option<String>)> = sqlx::query_as(
        "SELECT id, user_id, device_id FROM refresh_tokens \
         WHERE token_hash = $1 AND revoked_at IS NULL AND expires_at > now()",
    )
    .bind(&hash)
    .fetch_optional(&st.db)
    .await?;
    let (token_id, user_id, prev_device_id) = row.ok_or(AppError::Unauthorized)?;

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

    if matches!(user.status, UserStatus::Suspended | UserStatus::Banned) {
        return Err(AppError::forbidden(
            ErrorCode::AccountSuspended,
            "this account has been suspended",
        ));
    }

    // Carry the device id forward across rotation — an older app build that
    // doesn't send one on refresh shouldn't lose the identity the original
    // login recorded.
    let device_id = body.device_id.or(prev_device_id);
    let (pair, _new_token_id) = issue_tokens(&st, &user, device_id.as_deref()).await?;
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

async fn issue_tokens(
    st: &AppState,
    user: &User,
    device_id: Option<&str>,
) -> AppResult<(TokenPair, Uuid)> {
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

    let new_id: Uuid = sqlx::query_scalar(
        "INSERT INTO refresh_tokens (user_id, token_hash, expires_at, device_id) \
         VALUES ($1, $2, $3, $4) RETURNING id",
    )
    .bind(user.id)
    .bind(&refresh_hash)
    .bind(expires_at)
    .bind(device_id)
    .fetch_one(&st.db)
    .await?;

    Ok((
        TokenPair {
            access_token: access,
            refresh_token: refresh,
            user: user.clone(),
        },
        new_id,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers_with(xff: Option<&str>) -> HeaderMap {
        let mut h = HeaderMap::new();
        if let Some(v) = xff {
            h.insert("x-forwarded-for", v.parse().unwrap());
        }
        h
    }

    #[test]
    fn client_ip_reads_last_hop_of_x_forwarded_for() {
        // The last entry is the one *our* trusted proxy (Traefik) appended —
        // the first entry ("203.0.113.4" here) is client-supplied and must
        // never be trusted, since a caller could set it to dodge their limit.
        assert_eq!(
            client_ip(&headers_with(Some("203.0.113.4, 10.0.0.1"))),
            "10.0.0.1"
        );
    }

    #[test]
    fn client_ip_trims_whitespace() {
        assert_eq!(
            client_ip(&headers_with(Some("203.0.113.4, 10.0.0.1 "))),
            "10.0.0.1"
        );
    }

    #[test]
    fn client_ip_uses_the_only_entry_when_unproxied() {
        assert_eq!(client_ip(&headers_with(Some("203.0.113.4"))), "203.0.113.4");
    }

    #[test]
    fn client_ip_falls_back_when_header_missing() {
        assert_eq!(client_ip(&headers_with(None)), "unknown");
    }

    #[test]
    fn client_ip_falls_back_when_header_empty() {
        assert_eq!(client_ip(&headers_with(Some(""))), "unknown");
    }
}
