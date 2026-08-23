//! Standard API response codes. Every API error carries a stable, machine-
//! readable `ErrorCode` so clients can render a **localized** message
//! (Nepali / English / …) without parsing English text. The `message` field in
//! the body is only a developer-facing default.
//!
//! Wire format for errors: `{ "error": { "code": "INSUFFICIENT_CREDITS", "message": "…" } }`

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ErrorCode {
    // Generic
    Validation,
    Unauthorized,
    Forbidden,
    NotFound,
    RateLimited,
    Conflict,
    Internal,
    /// A feature is turned off from the admin dashboard (circuit breaker).
    FeatureDisabled,
    // Auth / identity
    PhoneInvalid,
    OtpInvalid,
    OtpRateLimited,
    DocumentInvalid,
    /// The account is suspended or banned — OTP verify/refresh both check
    /// this before issuing a token, not just KYC/onboarding-gated actions.
    AccountSuspended,
    // Rides / dispatch
    InvalidVehicleClass,
    InvalidStatus,
    InvalidPaymentMethod,
    TripUnavailable,
    OfferExpired,
    /// Too many accept-then-cancel trips in the trailing window (see
    /// `dispatch::MAX_DRIVER_CANCELS_PER_WINDOW`) — temporarily blocked from
    /// accepting new offers.
    TooManyCancellations,
    // Money
    InsufficientCredits,
    InsufficientDriverCredits,
    AmountInvalid,
    // Campaigns / plans
    InvalidCode,
    DuplicateCode,
    PlanInvalid,
    // Partnership / fleets
    DriverAlreadyInFleet,
    PartnerSuspended,
    /// A corporate ride tab can't cover this trip (no active tab, wallet, or cap).
    CorporateTabUnavailable,
}
