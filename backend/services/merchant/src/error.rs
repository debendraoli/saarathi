//! Uniform API error type: `{ "error": { "code", "message" } }`, matching
//! every other service so clients localize by code.

use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use saarathi_core::api::ErrorCode;
use serde_json::json;

#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("{0}")]
    BadRequest(String),
    #[error("{2}")]
    Coded(StatusCode, ErrorCode, String),
    #[error("forbidden")]
    Forbidden,
    #[error("not found")]
    NotFound,
    #[error(transparent)]
    Db(#[from] sqlx::Error),
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

impl AppError {
    pub fn bad(code: ErrorCode, msg: impl Into<String>) -> Self {
        AppError::Coded(StatusCode::BAD_REQUEST, code, msg.into())
    }
}

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

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, code, message) = match self {
            AppError::BadRequest(m) => (StatusCode::BAD_REQUEST, ErrorCode::Validation, m),
            AppError::Coded(s, c, m) => (s, c, m),
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
