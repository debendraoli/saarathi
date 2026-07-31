//! Shared application state and the auth extractors.

use crate::config::Config;
use crate::error::AppError;
use crate::store::DocumentStore;
use crate::token::{verify_access, Claims};
use axum::extract::FromRequestParts;
use axum::http::header::AUTHORIZATION;
use axum::http::request::Parts;
use sqlx::PgPool;
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub db: PgPool,
    pub config: Arc<Config>,
    pub docs: Arc<dyn DocumentStore>,
}

/// Any authenticated user (valid access token).
pub struct AuthUser(pub Claims);

impl FromRequestParts<AppState> for AuthUser {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        let header = parts
            .headers
            .get(AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .ok_or(AppError::Unauthorized)?;
        let token = header.strip_prefix("Bearer ").ok_or(AppError::Unauthorized)?;
        let claims = verify_access(&state.config.jwt_secret, token).map_err(|_| AppError::Unauthorized)?;
        Ok(AuthUser(claims))
    }
}

/// A staff (dashboard) user — any non-rider, non-driver role.
pub struct StaffUser(pub Claims);

impl FromRequestParts<AppState> for StaffUser {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        let AuthUser(claims) = AuthUser::from_request_parts(parts, state).await?;
        if !claims.role.is_staff() {
            return Err(AppError::Forbidden);
        }
        Ok(StaffUser(claims))
    }
}
