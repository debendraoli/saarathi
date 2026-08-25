//! WebRTC ICE configuration. Hands the app a STUN server and short-lived TURN
//! credentials for our self-hosted Coturn (`use-auth-secret` REST scheme:
//! username = "<expiry>:<user_id>", password = base64(HMAC-SHA1(secret, username))).
//! Falls back to a public STUN when no TURN secret is configured (dev).

use crate::auth::AuthUser;
use crate::state::AppState;
use axum::extract::State;
use axum::{routing::get, Json, Router};
use base64::Engine;
use chrono::Utc;
use hmac::{Hmac, KeyInit, Mac};
use serde_json::{json, Value};
use sha1::Sha1;

type HmacSha1 = Hmac<Sha1>;

pub fn routes() -> Router<AppState> {
    Router::new().route("/v1/rtc/ice", get(ice))
}

async fn ice(State(st): State<AppState>, AuthUser(claims): AuthUser) -> Json<Value> {
    let cfg = &st.config;
    let mut servers = vec![json!({ "urls": [cfg.turn_stun_url] })];

    if !cfg.turn_secret.is_empty() && !cfg.turn_urls.is_empty() {
        let expiry = Utc::now().timestamp() + cfg.turn_ttl_secs;
        let username = format!("{expiry}:{}", claims.sub);
        let mut mac = HmacSha1::new_from_slice(cfg.turn_secret.as_bytes())
            .expect("HMAC accepts any key length");
        mac.update(username.as_bytes());
        let credential =
            base64::engine::general_purpose::STANDARD.encode(mac.finalize().into_bytes());
        servers.push(json!({
            "urls": cfg.turn_urls,
            "username": username,
            "credential": credential,
        }));
    }

    Json(json!({ "ttl": cfg.turn_ttl_secs, "ice_servers": servers }))
}
