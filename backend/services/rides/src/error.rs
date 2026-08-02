//! Uniform API error type. Every error renders as
//! `{ "error": { "code": <ErrorCode>, "message": <string> } }` so clients can
//! localize by code (see `saarathi_core::api::ErrorCode`).

use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use saarathi_core::api::ErrorCode;
use serde_json::json;

#[derive(Debug, thiserror::Error)]
pub enum AppError {
    /// An error with an explicit status + machine-readable code.
    #[error("{2}")]
    Coded(StatusCode, ErrorCode, String),
    #[error("{0}")]
    BadRequest(String),
    #[error("unauthorized")]
    Unauthorized,
    #[error("forbidden")]
    Forbidden,
    #[error("not found")]
    NotFound,
    #[allow(dead_code)] // constructed via AppError::conflict(code, …)
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
        AppError::Coded(StatusCode::BAD_REQUEST, code, msg.into())
    }
    /// A 409 with a specific code.
    pub fn conflict(code: ErrorCode, msg: impl Into<String>) -> Self {
        AppError::Coded(StatusCode::CONFLICT, code, msg.into())
    }
    /// A 503: a feature has been turned off from the admin dashboard.
    pub fn disabled(msg: impl Into<String>) -> Self {
        AppError::Coded(
            StatusCode::SERVICE_UNAVAILABLE,
            ErrorCode::FeatureDisabled,
            msg.into(),
        )
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
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
            Json(json!({ "error": { "code": code, "message": message } })),
        )
            .into_response()
    }
}

pub type AppResult<T> = Result<T, AppError>;

impl From<saarathi_core::wallet::WalletError> for AppError {
    fn from(e: saarathi_core::wallet::WalletError) -> Self {
        use saarathi_core::wallet::WalletError;
        match e {
            WalletError::Db(db) => AppError::Db(db),
            other => {
                let code = other.code().unwrap_or(ErrorCode::Validation);
                AppError::bad(code, other.to_string())
            }
        }
    }
}
