//! OTP delivery: WhatsApp (Meta Cloud API) primary, Sparrow SMS fallback on
//! any WhatsApp failure (unregistered number, template not approved,
//! transient error — the brief doesn't distinguish these, so neither do we;
//! any non-success falls back rather than trying to special-case Meta's
//! error codes for "not on WhatsApp", which aren't reliably documented).
//!
//! Researched against live docs 2026-08-21 (not reconstructed from memory,
//! per this repo's rule for payment/OTP/SMS integrations):
//! - WhatsApp Cloud API: `POST https://graph.facebook.com/{version}/{phone_number_id}/messages`,
//!   `Authorization: Bearer <token>`, template message with an AUTHENTICATION-category
//!   template (body param = code, COPY_CODE button param = code). See
//!   developers.facebook.com/documentation/business-messaging/whatsapp/templates/authentication-templates.
//!   The template itself (name, language, wording) must be pre-created and
//!   approved in Meta Business Manager — this module only sends against an
//!   already-registered template name.
//! - Sparrow SMS: `GET https://api.sparrowsms.com/v2/sms/?token=..&from=..&to=..&text=..`,
//!   `to` is a bare 10-digit Nepali mobile number (no `+977`/country code).
//!   Success: `{"response_code": 200, ...}`. See docs.sparrowsms.com/sms/outgoing_sendsms.

use serde_json::json;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Channel {
    WhatsApp,
    Sms,
}

#[derive(Clone)]
pub struct WhatsAppConfig {
    pub api_version: String,
    pub phone_number_id: String,
    pub access_token: String,
    pub template_name: String,
    pub language_code: String,
}

impl std::fmt::Debug for WhatsAppConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WhatsAppConfig")
            .field("api_version", &self.api_version)
            .field("phone_number_id", &self.phone_number_id)
            .field("access_token", &"<redacted>")
            .field("template_name", &self.template_name)
            .field("language_code", &self.language_code)
            .finish()
    }
}

#[derive(Clone)]
pub struct SparrowConfig {
    pub token: String,
    pub from: String,
}

impl std::fmt::Debug for SparrowConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SparrowConfig")
            .field("token", &"<redacted>")
            .field("from", &self.from)
            .finish()
    }
}

pub struct OtpDelivery {
    http: reqwest::Client,
    whatsapp: Option<WhatsAppConfig>,
    sparrow: Option<SparrowConfig>,
}

impl OtpDelivery {
    pub fn new(whatsapp: Option<WhatsAppConfig>, sparrow: Option<SparrowConfig>) -> Self {
        Self {
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(10))
                .build()
                .expect("http client"),
            whatsapp,
            sparrow,
        }
    }

    /// Send the OTP, trying WhatsApp first (if configured) and falling back
    /// to Sparrow SMS on any failure. Errors only if every configured
    /// channel failed (or none are configured).
    pub async fn send(&self, phone: &str, code: &str) -> anyhow::Result<Channel> {
        if let Some(wa) = &self.whatsapp {
            match self.send_whatsapp(wa, phone, code).await {
                Ok(()) => return Ok(Channel::WhatsApp),
                Err(e) => {
                    tracing::warn!(error = %e, %phone, "whatsapp OTP send failed, falling back to SMS")
                }
            }
        }
        if let Some(sp) = &self.sparrow {
            self.send_sparrow(sp, phone, code).await?;
            return Ok(Channel::Sms);
        }
        anyhow::bail!("no OTP delivery channel available (WhatsApp failed/unset, Sparrow unset)")
    }

    async fn send_whatsapp(
        &self,
        cfg: &WhatsAppConfig,
        phone: &str,
        code: &str,
    ) -> anyhow::Result<()> {
        // Meta wants the number without the leading '+'.
        let to = phone.trim_start_matches('+');
        let body = json!({
            "messaging_product": "whatsapp",
            "to": to,
            "type": "template",
            "template": {
                "name": cfg.template_name,
                "language": { "code": cfg.language_code },
                "components": [
                    {
                        "type": "body",
                        "parameters": [{ "type": "text", "text": code }]
                    },
                    {
                        "type": "button",
                        "sub_type": "copy_code",
                        "index": "0",
                        "parameters": [{ "type": "text", "text": code }]
                    }
                ]
            }
        });
        let url = format!(
            "https://graph.facebook.com/{}/{}/messages",
            cfg.api_version, cfg.phone_number_id
        );
        let resp = self
            .http
            .post(&url)
            .bearer_auth(&cfg.access_token)
            .json(&body)
            .send()
            .await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            anyhow::bail!("whatsapp send {status}: {text}");
        }
        Ok(())
    }

    async fn send_sparrow(
        &self,
        cfg: &SparrowConfig,
        phone: &str,
        code: &str,
    ) -> anyhow::Result<()> {
        // Sparrow wants a bare 10-digit Nepali mobile number.
        let to = phone.trim_start_matches("+977");
        let text = format!("{code} is your Saarathi verification code. Do not share this code.");
        #[derive(serde::Deserialize)]
        struct SparrowResponse {
            response_code: i32,
            #[serde(default)]
            response: String,
        }
        let resp = self
            .http
            .get("https://api.sparrowsms.com/v2/sms/")
            .query(&[
                ("token", cfg.token.as_str()),
                ("from", cfg.from.as_str()),
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
