//! One-time password generation, hashing, and verification.

use argon2::password_hash::{PasswordHash, SaltString, rand_core::OsRng};
use argon2::{Argon2, PasswordHasher, PasswordVerifier};
use rand::RngExt;
use rand::rand_core::UnwrapErr;

/// A fresh 6-digit numeric code (zero-padded).
pub fn generate_code() -> String {
    let n: u32 = UnwrapErr(rand::rngs::SysRng).random_range(0..1_000_000);
    format!("{n:06}")
}

pub fn hash_code(code: &str) -> anyhow::Result<String> {
    let salt = SaltString::generate(&mut OsRng);
    let hash = Argon2::default()
        .hash_password(code.as_bytes(), &salt)
        .map_err(|e| anyhow::anyhow!("otp hash: {e}"))?
        .to_string();
    Ok(hash)
}

pub fn verify_code(code: &str, hash: &str) -> bool {
    match PasswordHash::new(hash) {
        Ok(parsed) => Argon2::default()
            .verify_password(code.as_bytes(), &parsed)
            .is_ok(),
        Err(_) => false,
    }
}

/// Lightweight E.164 validation (no external regex dep).
pub fn valid_phone(phone: &str) -> bool {
    let bytes = phone.as_bytes();
    bytes.len() >= 8
        && bytes.len() <= 16
        && bytes[0] == b'+'
        && bytes[1] != b'0'
        && bytes[1..].iter().all(|b| b.is_ascii_digit())
}
