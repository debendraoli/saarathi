//! Standard API response codes. Every API error carries a stable, machine-
//! readable `ErrorCode` so clients can render a **localized** message
//! (Nepali / English / …) without parsing English text. The `message` field in
//! the body is only a developer-facing default.
//!
//! Wire format for errors: `{ "error": { "code": "INSUFFICIENT_CREDITS", "message": "…" } }`

use serde::{Deserialize, Serialize};

/// Header names shared between services. A mismatch between the name a
/// caller sends and the name a callee checks silently disables the guard
/// (internal secret) or breaks replay-safety (idempotency key), so both
/// sides must go through these constants rather than retyping the literal.
pub mod headers {
    /// Guards `/v1/internal/*` service-to-service routes (never gateway-routed).
    pub const X_INTERNAL_SECRET: &str = "x-internal-secret";
    /// Idempotency key for payment/order-mutating ops; see `idempotency` module.
    pub const X_IDEMPOTENCY_KEY: &str = "x-idempotency-key";
}

/// Checks the internal-secret header against `expected`. If `expected` is
/// empty (`INTERNAL_SERVICE_SECRET` unset), logs a warning and allows the
/// request through — a dev convenience so `/v1/internal/*` still works
/// without a keystore/secret configured locally.
pub fn check_internal_secret(expected: &str, req_headers: &axum::http::HeaderMap) -> bool {
    if expected.is_empty() {
        tracing::warn!("INTERNAL_SERVICE_SECRET unset; /v1/internal/* is unauthenticated");
        return true;
    }
    req_headers
        .get(headers::X_INTERNAL_SECRET)
        .and_then(|v| v.to_str().ok())
        == Some(expected)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ErrorCode {
    // Generic
    Validation,
    Unauthorized,
    Forbidden,
    NotFound,
    RateLimited,
    Conflict,
    Internal,
    /// A feature is turned off from the admin dashboard (circuit breaker).
    FeatureDisabled,
    // Auth / identity
    PhoneInvalid,
    OtpInvalid,
    OtpRateLimited,
    DocumentInvalid,
    /// The account is suspended or banned — OTP verify/refresh both check
    /// this before issuing a token, not just KYC/onboarding-gated actions.
    AccountSuspended,
    // Rides / dispatch
    InvalidVehicleClass,
    InvalidStatus,
    InvalidPaymentMethod,
    TripUnavailable,
    OfferExpired,
    /// Too many accept-then-cancel trips in the trailing window (see
    /// `dispatch::MAX_DRIVER_CANCELS_PER_WINDOW`) — temporarily blocked from
    /// accepting new offers.
    TooManyCancellations,
    // Money
    InsufficientCredits,
    InsufficientDriverCredits,
    AmountInvalid,
    // Campaigns / plans
    InvalidCode,
    DuplicateCode,
    PlanInvalid,
    // Partnership / fleets
    DriverAlreadyInFleet,
    PartnerSuspended,
    /// A corporate ride tab can't cover this trip (no active tab, wallet, or cap).
    CorporateTabUnavailable,
}

/// Uniform API error type, shared by every service so the JSON error shape
/// (`{ "error": { "code": ..., "message": ... } }`) and status-code mapping
/// stay identical everywhere instead of being reimplemented per service.
/// A service adds its own variants only for genuinely service-specific
/// error shapes (e.g. payments' provider errors) via a local `From` impl or
/// wrapper — most services never need to.
#[derive(Debug, thiserror::Error)]
pub enum AppError {
    /// An error with an explicit status + machine-readable code.
    #[error("{2}")]
    Coded(axum::http::StatusCode, ErrorCode, String),
    #[error("{0}")]
    BadRequest(String),
    #[error("unauthorized")]
    Unauthorized,
    #[error("forbidden")]
    Forbidden,
    #[error("not found")]
    NotFound,
    #[error("too many requests")]
    RateLimited,
    #[error("{0}")]
    Conflict(String),
    #[error(transparent)]
    Db(#[from] sqlx::Error),
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

impl AppError {
    /// A 400 with a specific code.
    pub fn bad(code: ErrorCode, msg: impl Into<String>) -> Self {
        AppError::Coded(axum::http::StatusCode::BAD_REQUEST, code, msg.into())
    }
    /// A 401 with a specific code (e.g. an invalid OTP).
    pub fn unauthorized(code: ErrorCode, msg: impl Into<String>) -> Self {
        AppError::Coded(axum::http::StatusCode::UNAUTHORIZED, code, msg.into())
    }
    /// A 429 with a specific code.
    pub fn rate_limited(code: ErrorCode, msg: impl Into<String>) -> Self {
        AppError::Coded(axum::http::StatusCode::TOO_MANY_REQUESTS, code, msg.into())
    }
    /// A 409 with a specific code.
    pub fn conflict(code: ErrorCode, msg: impl Into<String>) -> Self {
        AppError::Coded(axum::http::StatusCode::CONFLICT, code, msg.into())
    }
    /// A 403 with a specific code.
    pub fn forbidden(code: ErrorCode, msg: impl Into<String>) -> Self {
        AppError::Coded(axum::http::StatusCode::FORBIDDEN, code, msg.into())
    }
    /// A 503: a feature has been turned off from the admin dashboard.
    pub fn disabled(msg: impl Into<String>) -> Self {
        AppError::Coded(
            axum::http::StatusCode::SERVICE_UNAVAILABLE,
            ErrorCode::FeatureDisabled,
            msg.into(),
        )
    }
}

impl axum::response::IntoResponse for AppError {
    fn into_response(self) -> axum::response::Response {
        use axum::http::StatusCode;
        let (status, code, message) = match self {
            AppError::Coded(s, c, m) => (s, c, m),
            AppError::BadRequest(m) => (StatusCode::BAD_REQUEST, ErrorCode::Validation, m),
            AppError::Unauthorized => (
                StatusCode::UNAUTHORIZED,
                ErrorCode::Unauthorized,
                "unauthorized".into(),
            ),
            AppError::Forbidden => (
                StatusCode::FORBIDDEN,
                ErrorCode::Forbidden,
                "forbidden".into(),
            ),
            AppError::NotFound => (
                StatusCode::NOT_FOUND,
                ErrorCode::NotFound,
                "not found".into(),
            ),
            AppError::RateLimited => (
                StatusCode::TOO_MANY_REQUESTS,
                ErrorCode::RateLimited,
                "too many requests".into(),
            ),
            AppError::Conflict(m) => (StatusCode::CONFLICT, ErrorCode::Conflict, m),
            AppError::Db(e) => {
                tracing::error!(error = ?e, "database error");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    ErrorCode::Internal,
                    "internal error".into(),
                )
            }
            AppError::Other(e) => {
                tracing::error!(error = ?e, "internal error");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    ErrorCode::Internal,
                    "internal error".into(),
                )
            }
        };
        (
            status,
            axum::Json(
                serde_json::json!({ "error": { "code": code, "message": message } }),
            ),
        )
            .into_response()
    }
}

pub type AppResult<T> = Result<T, AppError>;

impl From<crate::wallet::WalletError> for AppError {
    fn from(e: crate::wallet::WalletError) -> Self {
        use crate::wallet::WalletError;
        match e {
            WalletError::Db(db) => AppError::Db(db),
            other => {
                let code = other.code().unwrap_or(ErrorCode::Validation);
                AppError::bad(code, other.to_string())
            }
        }
    }
}

impl From<crate::idempotency::IdempotencyError> for AppError {
    fn from(e: crate::idempotency::IdempotencyError) -> Self {
        use crate::idempotency::IdempotencyError;
        match e {
            IdempotencyError::Db(db) => AppError::Db(db),
            IdempotencyError::InFlight => AppError::conflict(ErrorCode::Conflict, e.to_string()),
        }
    }
}

impl From<crate::payments::ProviderError> for AppError {
    fn from(e: crate::payments::ProviderError) -> Self {
        tracing::error!(error = %e, "payment provider error");
        AppError::Coded(
            axum::http::StatusCode::BAD_GATEWAY,
            ErrorCode::Internal,
            "payment provider is unavailable".into(),
        )
    }
}
