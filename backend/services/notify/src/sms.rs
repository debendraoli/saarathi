//! SMS fallback for critical notifications (safety/transactional/compliance)
//! that push couldn't reach — no device token registered, or every FCM send
//! failed. Sparrow SMS only (same provider auth already uses for OTP
//! fallback; see `services/auth/src/otp_delivery.rs` for the researched API
//! shape — `to` is a bare 10-digit Nepali mobile number, no `+977`).
//! Env-gated: `None` when unconfigured, so critical notifications still work
//! (push-only) on a deployment without Sparrow credentials.

use serde::Deserialize;

pub struct SmsSender {
    http: reqwest::Client,
    token: String,
    from: String,
}

impl SmsSender {
    pub fn from_env() -> Option<Self> {
        let token = std::env::var("SPARROW_SMS_TOKEN")
            .ok()
            .filter(|v| !v.is_empty())?;
        let from = std::env::var("SPARROW_SMS_FROM")
            .ok()
            .filter(|v| !v.is_empty())?;
        tracing::info!("notify: SMS fallback enabled (Sparrow)");
        Some(Self {
            http: reqwest::Client::new(),
            token,
            from,
        })
    }

    pub async fn send(&self, phone: &str, title: &str, body: &str) -> anyhow::Result<()> {
        let to = phone.trim_start_matches("+977");
        // Keep it short — this is a fallback for a push the device never
        // got, not a full transcript.
        let text = if body.is_empty() {
            title.to_string()
        } else {
            format!("{title}: {body}")
        };
        #[derive(Deserialize)]
        struct SparrowResponse {
            response_code: i32,
            #[serde(default)]
            response: String,
        }
        let resp = self
            .http
            .get("https://api.sparrowsms.com/v2/sms/")
            .query(&[
                ("token", self.token.as_str()),
                ("from", self.from.as_str()),
                ("to", to),
                ("text", text.as_str()),
            ])
            .send()
            .await?;
        let status = resp.status();
        let parsed: SparrowResponse = resp.json().await?;
        if !status.is_success() || parsed.response_code != 200 {
            anyhow::bail!(
                "sparrow sms send failed (code {}): {}",
                parsed.response_code,
                parsed.response
            );
        }
        Ok(())
    }
}
