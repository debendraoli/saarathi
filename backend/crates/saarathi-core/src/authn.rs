//! Shared JWT verification + role-based extractors. Every service's own
//! `auth.rs` used to duplicate this near-verbatim (~90% identical across
//! campaigns/partners/payments/rides/notify, plus a re-typed variant in
//! auth's own `token.rs`/`state.rs`); this is the one implementation.
//!
//! Each service still keeps a thin `auth.rs` that re-exports what it needs
//! from here and implements [`HasJwtSecret`] for its own `AppState` — the
//! generic extractors below need a concrete `State` type to work with axum,
//! and every service nests its JWT secret differently (`state.jwt_secret`,
//! `state.config.jwt_secret`, `Arc<String>` vs `String`).

use crate::api::ErrorCode;
use axum::extract::FromRequestParts;
use axum::http::header::AUTHORIZATION;
use axum::http::request::Parts;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use jsonwebtoken::{decode, DecodingKey, Validation};
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

use crate::domain::roles;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Claims {
    pub sub: Uuid,
    pub role: String,
    pub iat: i64,
    pub exp: i64,
}

impl Claims {
    /// Any non-rider, non-driver role — the dashboard/staff side.
    pub fn is_staff(&self) -> bool {
        !matches!(self.role.as_str(), roles::RIDER | roles::DRIVER)
    }

    /// Roles allowed to approve/reject (maker-checker): admin & super-admin.
    /// Also what partners' domain calls a "partner admin" — same predicate.
    pub fn can_approve(&self) -> bool {
        matches!(self.role.as_str(), roles::SUPER_ADMIN | roles::ADMIN)
    }

    /// Roles allowed to make KYC approve/reject decisions (auth service).
    pub fn can_review_kyc(&self) -> bool {
        matches!(
            self.role.as_str(),
            roles::SUPER_ADMIN | roles::ADMIN | roles::COMPLIANCE
        )
    }
}

#[derive(Debug, thiserror::Error)]
pub enum AuthError {
    #[error("unauthorized")]
    Unauthorized,
    #[error("forbidden")]
    Forbidden,
}

/// Renders the same `{ "error": { "code", "message" } }` envelope every
/// service's own `AppError::Unauthorized`/`Forbidden` already rendered, so
/// swapping a service onto the shared extractor doesn't change its API
/// responses. (Exception: `saarathi-notify`, whose old inline extractor
/// returned a bare `StatusCode` with no body — this fixes that to match
/// every other service, a deliberate, flagged consistency improvement.)
impl IntoResponse for AuthError {
    fn into_response(self) -> Response {
        let (status, code, message) = match self {
            AuthError::Unauthorized => {
                (StatusCode::UNAUTHORIZED, ErrorCode::Unauthorized, "unauthorized")
            }
            AuthError::Forbidden => (StatusCode::FORBIDDEN, ErrorCode::Forbidden, "forbidden"),
        };
        (
            status,
            Json(json!({ "error": { "code": code, "message": message } })),
        )
            .into_response()
    }
}

pub fn verify_access(secret: &str, token: &str) -> Result<Claims, AuthError> {
    decode::<Claims>(
        token,
        &DecodingKey::from_secret(secret.as_bytes()),
        &Validation::default(),
    )
    .map(|d| d.claims)
    .map_err(|_| AuthError::Unauthorized)
}

/// Implemented by each service's `AppState` so the generic extractors below
/// can find the shared JWT secret regardless of where each state nests it.
pub trait HasJwtSecret {
    fn jwt_secret(&self) -> &str;
}

/// Any authenticated user (a valid access token).
pub struct AuthUser(pub Claims);

impl<S> FromRequestParts<S> for AuthUser
where
    S: HasJwtSecret + Send + Sync,
{
    type Rejection = AuthError;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, AuthError> {
        let header = parts
            .headers
            .get(AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .ok_or(AuthError::Unauthorized)?;
        let token = header
            .strip_prefix("Bearer ")
            .ok_or(AuthError::Unauthorized)?;
        Ok(AuthUser(verify_access(state.jwt_secret(), token)?))
    }
}

/// A staff (dashboard) user — any non-rider, non-driver role.
pub struct StaffUser(pub Claims);

impl<S> FromRequestParts<S> for StaffUser
where
    S: HasJwtSecret + Send + Sync,
{
    type Rejection = AuthError;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, AuthError> {
        let AuthUser(claims) = AuthUser::from_request_parts(parts, state).await?;
        if !claims.is_staff() {
            return Err(AuthError::Forbidden);
        }
        Ok(StaffUser(claims))
    }
}

/// A platform-admin user (super_admin / admin) — e.g. governs partners, or
/// approves/rejects maker-checker requests.
pub struct AdminUser(pub Claims);

impl<S> FromRequestParts<S> for AdminUser
where
    S: HasJwtSecret + Send + Sync,
{
    type Rejection = AuthError;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, AuthError> {
        let AuthUser(claims) = AuthUser::from_request_parts(parts, state).await?;
        if !claims.can_approve() {
            return Err(AuthError::Forbidden);
        }
        Ok(AdminUser(claims))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use jsonwebtoken::{encode, EncodingKey, Header};

    fn token_for(secret: &str, role: &str) -> String {
        let now = chrono::Utc::now().timestamp();
        let claims = Claims {
            sub: Uuid::new_v4(),
            role: role.to_string(),
            iat: now,
            exp: now + 900,
        };
        encode(&Header::default(), &claims, &EncodingKey::from_secret(secret.as_bytes())).unwrap()
    }

    #[test]
    fn verify_access_round_trips_a_validly_signed_token() {
        let token = token_for("s3cret", roles::RIDER);
        let claims = verify_access("s3cret", &token).expect("valid token verifies");
        assert_eq!(claims.role, roles::RIDER);
    }

    #[test]
    fn verify_access_rejects_wrong_secret() {
        let token = token_for("s3cret", roles::RIDER);
        assert!(matches!(
            verify_access("wrong-secret", &token),
            Err(AuthError::Unauthorized)
        ));
    }

    #[test]
    fn verify_access_rejects_garbage() {
        assert!(matches!(
            verify_access("s3cret", "not-a-jwt"),
            Err(AuthError::Unauthorized)
        ));
    }

    #[test]
    fn is_staff_excludes_only_rider_and_driver() {
        let claims_for = |role: &str| Claims {
            sub: Uuid::new_v4(),
            role: role.to_string(),
            iat: 0,
            exp: 0,
        };
        assert!(!claims_for(roles::RIDER).is_staff());
        assert!(!claims_for(roles::DRIVER).is_staff());
        assert!(claims_for(roles::ADMIN).is_staff());
        assert!(claims_for(roles::SUPPORT).is_staff());
    }

    #[test]
    fn can_approve_is_admin_and_super_admin_only() {
        let claims_for = |role: &str| Claims {
            sub: Uuid::new_v4(),
            role: role.to_string(),
            iat: 0,
            exp: 0,
        };
        assert!(claims_for(roles::SUPER_ADMIN).can_approve());
        assert!(claims_for(roles::ADMIN).can_approve());
        assert!(!claims_for(roles::COMPLIANCE).can_approve());
        assert!(!claims_for(roles::RIDER).can_approve());
    }

    #[test]
    fn can_review_kyc_includes_compliance() {
        let claims_for = |role: &str| Claims {
            sub: Uuid::new_v4(),
            role: role.to_string(),
            iat: 0,
            exp: 0,
        };
        assert!(claims_for(roles::COMPLIANCE).can_review_kyc());
        assert!(claims_for(roles::ADMIN).can_review_kyc());
        assert!(!claims_for(roles::SUPPORT).can_review_kyc());
        assert!(!claims_for(roles::DRIVER).can_review_kyc());
    }
}
