//! JWT verification (shares the JWT_SECRET with saarathi-auth) + extractors.

use crate::error::AppError;
use crate::state::AppState;
use axum::extract::FromRequestParts;
use axum::http::header::AUTHORIZATION;
use axum::http::request::Parts;
use jsonwebtoken::{decode, DecodingKey, Validation};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Claims {
    pub sub: Uuid,
    pub role: String,
    pub iat: i64,
    pub exp: i64,
}

impl Claims {
    pub fn is_staff(&self) -> bool {
        !matches!(self.role.as_str(), "rider" | "driver")
    }
}

pub fn verify_access(secret: &str, token: &str) -> Result<Claims, AppError> {
    decode::<Claims>(token, &DecodingKey::from_secret(secret.as_bytes()), &Validation::default())
        .map(|d| d.claims)
        .map_err(|_| AppError::Unauthorized)
}

/// Any authenticated user.
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
        Ok(AuthUser(verify_access(&state.config.jwt_secret, token)?))
    }
}

/// A staff (dashboard) user.
pub struct StaffUser(pub Claims);

impl FromRequestParts<AppState> for StaffUser {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        let AuthUser(claims) = AuthUser::from_request_parts(parts, state).await?;
        if !claims.is_staff() {
            return Err(AppError::Forbidden);
        }
        Ok(StaffUser(claims))
    }
}
