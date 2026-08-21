//! Payment-service-provider hand-off, shared by every service that starts a
//! top-up. [`KhaltiProvider`] talks to Khalti's ePayment API
//! (docs.khalti.com/khalti-epayment/) — confirmed live 2026-08-21. Khalti has
//! **no signed webhook**: the only trust boundary is a server-to-server
//! "Lookup" call authenticated with our own secret key. So callers must never
//! credit anything off the browser's `return_url` query params — only off
//! [`PaymentProvider::verify_topup`], which is what actually calls Lookup.
//! `MockProvider` lets the whole flow run end-to-end in dev/test without live
//! credentials, mirroring `saarathi-routing`'s empty-`ROUTING_URL` fallback.

use async_trait::async_trait;
use rust_decimal::prelude::ToPrimitive;
use rust_decimal::Decimal;
use uuid::Uuid;

pub struct TopupInit {
    pub reference: String,
    pub checkout_url: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VerifyOutcome {
    Completed,
    Pending,
    Failed,
}

#[derive(Debug, thiserror::Error)]
pub enum ProviderError {
    #[error("payment provider request failed: {0}")]
    Request(String),
    #[error("payment provider returned an unexpected response: {0}")]
    Unexpected(String),
}

#[async_trait]
pub trait PaymentProvider: Send + Sync {
    fn name(&self) -> &'static str;
    /// Begin a top-up; returns a reference and the URL the client redirects
    /// to. `purchase_order_id` is caller-generated (Khalti requires one).
    async fn start_topup(
        &self,
        user_id: Uuid,
        amount: Decimal,
        purchase_order_id: &str,
    ) -> Result<TopupInit, ProviderError>;
    /// The only thing callers may trust to confirm a top-up actually paid —
    /// a fresh server-to-server check, never the client's own claim.
    async fn verify_topup(
        &self,
        reference: &str,
        expected_amount: Decimal,
    ) -> Result<VerifyOutcome, ProviderError>;
    /// Begin a payout; returns a provider reference. Real disbursement is a
    /// separate, whitelisted Khalti product not wired up in this pass —
    /// payouts stay simulated for every provider, including Khalti.
    fn start_payout(&self, recipient_id: Uuid, amount: Decimal) -> String;
}

/// Dev/test provider — references are UUIDs, top-ups verify instantly.
pub struct MockProvider;

#[async_trait]
impl PaymentProvider for MockProvider {
    fn name(&self) -> &'static str {
        "mock"
    }
    async fn start_topup(
        &self,
        _user_id: Uuid,
        _amount: Decimal,
        _purchase_order_id: &str,
    ) -> Result<TopupInit, ProviderError> {
        let reference = Uuid::new_v4().to_string();
        Ok(TopupInit {
            checkout_url: format!("mock://pay/{reference}"),
            reference,
        })
    }
    async fn verify_topup(
        &self,
        _reference: &str,
        _expected_amount: Decimal,
    ) -> Result<VerifyOutcome, ProviderError> {
        Ok(VerifyOutcome::Completed)
    }
    fn start_payout(&self, _recipient_id: Uuid, _amount: Decimal) -> String {
        Uuid::new_v4().to_string()
    }
}

/// Khalti ePayment (Web Checkout) — pidx-based initiate + Lookup, the current
/// integration path per docs.khalti.com/khalti-epayment/ (superseding the
/// older token+amount `/payment/verify/` widget flow).
pub struct KhaltiProvider {
    http: reqwest::Client,
    /// e.g. `https://dev.khalti.com/api/v2` (sandbox) or
    /// `https://khalti.com/api/v2` (prod) — no trailing slash.
    base_url: String,
    secret_key: String,
    return_url: String,
    website_url: String,
}

impl KhaltiProvider {
    pub fn new(base_url: String, secret_key: String, return_url: String, website_url: String) -> Self {
        Self {
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(10))
                .build()
                .expect("http client"),
            base_url: base_url.trim_end_matches('/').to_string(),
            secret_key,
            return_url,
            website_url,
        }
    }

    fn auth_header(&self) -> String {
        format!("Key {}", self.secret_key)
    }
}

#[derive(serde::Serialize)]
struct InitiateRequest<'a> {
    return_url: &'a str,
    website_url: &'a str,
    /// Smallest unit — 1 NPR = 100 paisa. Khalti's minimum is 1000 (NPR 10).
    amount: i64,
    purchase_order_id: &'a str,
    purchase_order_name: &'a str,
}

#[derive(serde::Deserialize)]
struct InitiateResponse {
    pidx: String,
    payment_url: String,
}

#[derive(serde::Serialize)]
struct LookupRequest<'a> {
    pidx: &'a str,
}

#[derive(serde::Deserialize)]
struct LookupResponse {
    status: String,
    total_amount: i64,
}

/// NPR (Decimal) → integer paisa, as Khalti's API requires. Distinct from
/// `Money::round_paisa`, which just rounds a Decimal to 2dp and stays in NPR.
fn to_khalti_paisa(npr: Decimal) -> i64 {
    (npr * Decimal::from(100))
        .round()
        .to_i64()
        .unwrap_or(i64::MAX)
}

#[async_trait]
impl PaymentProvider for KhaltiProvider {
    fn name(&self) -> &'static str {
        "khalti"
    }

    async fn start_topup(
        &self,
        _user_id: Uuid,
        amount: Decimal,
        purchase_order_id: &str,
    ) -> Result<TopupInit, ProviderError> {
        let body = InitiateRequest {
            return_url: &self.return_url,
            website_url: &self.website_url,
            amount: to_khalti_paisa(amount),
            purchase_order_id,
            purchase_order_name: "Saarathi credits top-up",
        };
        let resp = self
            .http
            .post(format!("{}/epayment/initiate/", self.base_url))
            .header("Authorization", self.auth_header())
            .json(&body)
            .send()
            .await
            .map_err(|e| ProviderError::Request(e.to_string()))?;
        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            return Err(ProviderError::Unexpected(format!(
                "initiate {status}: {text}"
            )));
        }
        let parsed: InitiateResponse = resp
            .json()
            .await
            .map_err(|e| ProviderError::Unexpected(e.to_string()))?;
        Ok(TopupInit {
            reference: parsed.pidx,
            checkout_url: parsed.payment_url,
        })
    }

    async fn verify_topup(
        &self,
        reference: &str,
        expected_amount: Decimal,
    ) -> Result<VerifyOutcome, ProviderError> {
        let resp = self
            .http
            .post(format!("{}/epayment/lookup/", self.base_url))
            .header("Authorization", self.auth_header())
            .json(&LookupRequest { pidx: reference })
            .send()
            .await
            .map_err(|e| ProviderError::Request(e.to_string()))?;
        // Expired / User canceled / not-found lookups come back as 4xx.
        if !resp.status().is_success() {
            return Ok(VerifyOutcome::Failed);
        }
        let parsed: LookupResponse = resp
            .json()
            .await
            .map_err(|e| ProviderError::Unexpected(e.to_string()))?;
        if parsed.status != "Completed" {
            return Ok(match parsed.status.as_str() {
                "Pending" | "Initiated" => VerifyOutcome::Pending,
                _ => VerifyOutcome::Failed,
            });
        }
        // Never trust status alone — the amount actually paid must match what
        // we quoted, or a tampered/mismatched pidx could under-pay us.
        if parsed.total_amount != to_khalti_paisa(expected_amount) {
            tracing::error!(
                pidx = reference,
                expected_paisa = to_khalti_paisa(expected_amount),
                got_paisa = parsed.total_amount,
                "khalti lookup amount mismatch"
            );
            return Ok(VerifyOutcome::Failed);
        }
        Ok(VerifyOutcome::Completed)
    }

    fn start_payout(&self, recipient_id: Uuid, _amount: Decimal) -> String {
        format!("khalti-payout-unimplemented-{recipient_id}")
    }
}

/// Picks `KhaltiProvider` when `KHALTI_SECRET_KEY` is configured, else
/// `MockProvider` — mirrors `saarathi-routing`'s empty-`ROUTING_URL`
/// fallback, so local dev/smoke-testing works without live credentials.
/// Shared by every service that starts a top-up (`saarathi-payments`,
/// `saarathi-rides`), so provider selection can't drift between them.
pub fn provider_from_env() -> std::sync::Arc<dyn PaymentProvider> {
    let secret_key = std::env::var("KHALTI_SECRET_KEY")
        .ok()
        .filter(|v| !v.is_empty());
    match secret_key {
        Some(secret_key) => {
            let base_url = std::env::var("KHALTI_BASE_URL")
                .ok()
                .filter(|v| !v.is_empty())
                .unwrap_or_else(|| "https://dev.khalti.com/api/v2".to_string());
            let return_url = std::env::var("KHALTI_RETURN_URL").unwrap_or_default();
            let website_url = std::env::var("KHALTI_WEBSITE_URL").unwrap_or_default();
            tracing::info!(base_url, "using KhaltiProvider for payments");
            std::sync::Arc::new(KhaltiProvider::new(
                base_url,
                secret_key,
                return_url,
                website_url,
            ))
        }
        None => {
            tracing::info!("KHALTI_SECRET_KEY unset — using MockProvider for payments");
            std::sync::Arc::new(MockProvider)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal_macros::dec;

    #[test]
    fn paisa_conversion_matches_khaltis_smallest_unit() {
        assert_eq!(to_khalti_paisa(dec!(10)), 1000);
        assert_eq!(to_khalti_paisa(dec!(10.5)), 1050);
        assert_eq!(to_khalti_paisa(dec!(1234.56)), 123456);
    }

    #[test]
    fn paisa_conversion_rounds_sub_paisa_amounts() {
        // NPR has no sub-paisa denomination; round to the nearest paisa.
        assert_eq!(to_khalti_paisa(dec!(10.004)), 1000);
        assert_eq!(to_khalti_paisa(dec!(10.006)), 1001);
    }
}
