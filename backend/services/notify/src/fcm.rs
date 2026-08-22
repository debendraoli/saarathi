//! FCM HTTP v1 push sender. Env-gated — needs a Firebase service-account JSON
//! (FCM_SERVICE_ACCOUNT_JSON = path) and optionally FCM_PROJECT_ID. It mints an
//! OAuth2 access token by signing a JWT with the service-account key, caches it,
//! and POSTs notifications to the v1 send API. Absent config → sender is `None`
//! and push is skipped (the durable inbox still works).

use anyhow::Context;
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tokio::sync::Mutex;

/// Outcome of one send attempt. `StaleToken` means the token itself is dead
/// (FCM's `UNREGISTERED`, HTTP 404) — the caller should stop sending to it
/// rather than retry, and drop it from `device_tokens`. `Other` covers
/// anything else (auth, quota, transient network) — worth logging, not worth
/// deleting a token over.
pub enum SendError {
    StaleToken,
    Other(anyhow::Error),
}

impl From<anyhow::Error> for SendError {
    fn from(e: anyhow::Error) -> Self {
        SendError::Other(e)
    }
}

#[derive(Deserialize)]
struct ServiceAccount {
    client_email: String,
    private_key: String,
    token_uri: String,
    #[serde(default)]
    project_id: String,
}

#[derive(Serialize)]
struct AuthClaims<'a> {
    iss: &'a str,
    scope: &'a str,
    aud: &'a str,
    iat: i64,
    exp: i64,
}

pub struct FcmSender {
    project_id: String,
    sa: ServiceAccount,
    http: reqwest::Client,
    token: Mutex<Option<(String, i64)>>, // (access_token, expiry epoch secs)
}

impl FcmSender {
    /// Build from env, or `None` when unconfigured.
    pub fn from_env() -> Option<Arc<Self>> {
        let path = std::env::var("FCM_SERVICE_ACCOUNT_JSON")
            .ok()
            .filter(|s| !s.is_empty())?;
        let raw = match std::fs::read_to_string(&path) {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!(error = %e, %path, "notify: cannot read FCM service account");
                return None;
            }
        };
        let sa: ServiceAccount = match serde_json::from_str(&raw) {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(error = %e, "notify: invalid FCM service account JSON");
                return None;
            }
        };
        let project_id = std::env::var("FCM_PROJECT_ID")
            .ok()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| sa.project_id.clone());
        tracing::info!(%project_id, "notify: FCM push enabled");
        Some(Arc::new(Self {
            project_id,
            sa,
            http: reqwest::Client::new(),
            token: Mutex::new(None),
        }))
    }

    async fn access_token(&self) -> anyhow::Result<String> {
        let now = chrono::Utc::now().timestamp();
        {
            let guard = self.token.lock().await;
            if let Some((tok, exp)) = guard.as_ref() {
                if *exp - 60 > now {
                    return Ok(tok.clone());
                }
            }
        }
        let claims = AuthClaims {
            iss: &self.sa.client_email,
            scope: "https://www.googleapis.com/auth/firebase.messaging",
            aud: &self.sa.token_uri,
            iat: now,
            exp: now + 3600,
        };
        let jwt = encode(
            &Header::new(Algorithm::RS256),
            &claims,
            &EncodingKey::from_rsa_pem(self.sa.private_key.as_bytes())?,
        )?;
        let res: serde_json::Value = self
            .http
            .post(&self.sa.token_uri)
            .form(&[
                ("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"),
                ("assertion", &jwt),
            ])
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        let tok = res["access_token"]
            .as_str()
            .context("no access_token in token response")?
            .to_string();
        let mut guard = self.token.lock().await;
        *guard = Some((tok.clone(), now + 3600));
        Ok(tok)
    }

    /// Send one notification to one device token. `link`, when present, rides
    /// along as a data field so a tap can navigate straight to the relevant
    /// screen instead of just opening the app. Returns Ok on 2xx.
    pub async fn send(
        &self,
        token: &str,
        title: &str,
        body: &str,
        link: Option<&str>,
    ) -> Result<(), SendError> {
        let access = self.access_token().await?;
        let url = format!(
            "https://fcm.googleapis.com/v1/projects/{}/messages:send",
            self.project_id
        );
        let mut message = serde_json::json!({
            "token": token,
            "notification": { "title": title, "body": body }
        });
        if let Some(link) = link {
            message["data"] = serde_json::json!({ "link": link });
        }
        let payload = serde_json::json!({ "message": message });
        let resp = self
            .http
            .post(&url)
            .bearer_auth(access)
            .json(&payload)
            .send()
            .await
            .map_err(anyhow::Error::from)?;
        // FCM v1 reports a deregistered/invalid token as 404 UNREGISTERED —
        // the one case worth distinguishing since it means "stop sending to
        // this token", not just "this attempt failed".
        if resp.status().as_u16() == 404 {
            return Err(SendError::StaleToken);
        }
        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            return Err(SendError::Other(anyhow::anyhow!("fcm send {status}: {text}")));
        }
        Ok(())
    }
}
