//! Items shared across 2+ of the `rides` route submodules.

use crate::routing::LatLng;
use rust_decimal::Decimal;
use serde::Deserialize;

#[derive(Deserialize)]
pub(super) struct RideRequest {
    pub(super) origin: LatLng,
    pub(super) dest: LatLng,
    pub(super) vehicle_class: String,
    /// Optional intermediate waypoints (multi-stop rides).
    #[serde(default)]
    pub(super) stops: Vec<LatLng>,
    #[serde(default)]
    pub(super) code: Option<String>,
    /// 'cash' (default) or 'wallet' (pay from prepaid credits).
    #[serde(default)]
    pub(super) payment_method: Option<String>,
    /// Bounded fare bargaining: a rider's proposed fare (clamped to the legal
    /// band). In `pricing_mode: "bid"` this instead seeds the auction's
    /// initial ask (also clamped) rather than an immediately-agreed price.
    #[serde(default)]
    pub(super) offered_fare: Option<Decimal>,
    /// 'instant' (default: today's single algorithmic-fare dispatch) or
    /// 'bid' (open the trip to the fare auction — see `routes::bidding`).
    #[serde(default)]
    pub(super) pricing_mode: Option<String>,
    /// Starting dispatch search radius (km), overriding the service default.
    /// Set on a "search wider" re-request after a no-driver cancellation.
    #[serde(default)]
    pub(super) radius_km: Option<f64>,
    /// Request a specific driver by phone (someone this rider has ridden
    /// with before) — `dispatch_trip` tries them first, then falls back to
    /// normal matching. See `resolve_preferred_driver`.
    #[serde(default)]
    pub(super) preferred_driver_phone: Option<String>,
}
