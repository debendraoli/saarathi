//! JWT access token issuance + opaque refresh tokens. Verification is the
//! shared `saarathi_core::authn::verify_access` (see `crate::auth`) — this
//! module only signs, since only the issuer needs to.

use crate::models::UserRole;
use chrono::Utc;
use jsonwebtoken::{encode, EncodingKey, Header};
use rand::rand_core::UnwrapErr;
use rand::Rng;
use serde::Serialize;
use sha2::{Digest, Sha256};
use uuid::Uuid;

/// Issuance-only shape — `role` is the typed `UserRole` so callers can't pass
/// a bogus string; it serializes to the same snake_case string that
/// `saarathi_core::authn::Claims::role` (plain `String`) decodes on the
/// verification side, since `UserRole` derives `#[serde(rename_all =
/// "snake_case")]` matching `saarathi_core::domain::roles`'s constants.
#[derive(Debug, Clone, Serialize)]
struct Claims {
    sub: Uuid,
    role: UserRole,
    iat: i64,
    exp: i64,
}

pub fn issue_access(
    secret: &str,
    user_id: Uuid,
    role: UserRole,
    ttl_secs: i64,
) -> anyhow::Result<String> {
    let now = Utc::now().timestamp();
    let claims = Claims {
        sub: user_id,
        role,
        iat: now,
        exp: now + ttl_secs,
    };
    let token = encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )?;
    Ok(token)
}

/// A high-entropy opaque refresh token (returned to the client once).
pub fn generate_refresh_token() -> String {
    let mut bytes = [0u8; 32];
    UnwrapErr(rand::rngs::SysRng).fill_bytes(&mut bytes);
    hex::encode(bytes)
}

/// Only the hash of a refresh token is stored.
pub fn hash_token(token: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    hex::encode(hasher.finalize())
}
