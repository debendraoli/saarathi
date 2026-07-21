//! The pricing clamp — the server-side, final enforcement of the legal fare
//! ceilings. This is core IP and the single most compliance-sensitive function
//! in the system.
//!
//! The fare is computed as:
//!
//! ```text
//! base   = max(min_distance, distance_km) * per_km_rate      (per-km rate clamped to legal cap)
//! surge  = clamp(dynamic_multiplier, 1.00, 1.20)             (legal +20% ceiling)
//! fare   = base * surge
//! ```
//!
//! No matter what the admin dashboard configures, this function can never emit
//! a fare above the law: the per-km rate is clamped to the vehicle's cap and the
//! surge multiplier is clamped to +20%.

use crate::legal::{
    VehicleClass, ACCIDENT_FUND_RATE, MAX_COMMISSION_RATE, MAX_SURGE_MULTIPLIER, MIN_DISTANCE_KM,
    NO_SURGE_MULTIPLIER,
};
use crate::money::Money;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};

/// Runtime-configurable pricing inputs (set from the admin dashboard, per city /
/// vehicle / vertical). These are *requests*; [`quote_fare`] clamps them to the
/// legal caps before producing a fare.
#[derive(Debug, Clone, Copy)]
pub struct PricingConfig {
    /// Admin-configured per-km rate (NPR). Clamped to the vehicle's legal cap.
    pub per_km_rate: Decimal,
    /// Admin-configured commission rate (0.0–0.10). Clamped to the legal max.
    pub commission_rate: Decimal,
}

/// A fully-clamped, legally-safe fare breakdown ready for display and ledgering.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct FareQuote {
    /// The billable distance actually charged (>= legal minimum).
    pub billable_distance_km: Decimal,
    /// The effective per-km rate after clamping to the legal cap.
    pub effective_per_km_rate: Decimal,
    /// The effective surge multiplier after clamping to +20%.
    pub effective_surge: Decimal,
    /// Total fare charged to the rider.
    pub fare: Money,
    /// Platform commission (<= 10% of fare).
    pub commission: Money,
    /// Accident-fund levy (1% of fare).
    pub accident_fund: Money,
    /// Amount owed to the driver (fare - commission - fund).
    pub driver_payout: Money,
}

/// Clamp `value` into the inclusive range `[min, max]`.
fn clamp(value: Decimal, min: Decimal, max: Decimal) -> Decimal {
    value.max(min).min(max)
}

/// Compute a legally-safe fare quote.
///
/// `distance_km` is the routed trip distance. `dynamic_multiplier` is the raw
/// surge/night/weather multiplier proposed by the pricing engine; it is clamped
/// to `[1.00, 1.20]` here. The per-km rate is clamped to the vehicle's legal cap.
pub fn quote_fare(
    vehicle: VehicleClass,
    distance_km: Decimal,
    dynamic_multiplier: Decimal,
    config: PricingConfig,
) -> FareQuote {
    // 1. Per-km rate can never exceed the vehicle's legal ceiling.
    let effective_per_km_rate = clamp(config.per_km_rate, Decimal::ZERO, vehicle.per_km_cap());

    // 2. Fares are billed for at least the legal minimum distance.
    let billable_distance_km = distance_km.max(MIN_DISTANCE_KM);

    // 3. Surge is clamped to the legal +20% ceiling.
    let effective_surge = clamp(dynamic_multiplier, NO_SURGE_MULTIPLIER, MAX_SURGE_MULTIPLIER);

    // 4. Assemble the fare.
    let base = Money::from_decimal(billable_distance_km * effective_per_km_rate);
    let fare = Money::from_decimal(base.amount() * effective_surge).round_paisa();

    // 5. Commission is clamped to the legal max; the fund is a fixed 1%.
    let commission_rate = clamp(config.commission_rate, Decimal::ZERO, MAX_COMMISSION_RATE);
    let commission = fare.scale(commission_rate).round_paisa();
    let accident_fund = fare.scale(ACCIDENT_FUND_RATE).round_paisa();
    let driver_payout = (fare - commission - accident_fund).round_paisa();

    FareQuote {
        billable_distance_km,
        effective_per_km_rate,
        effective_surge,
        fare,
        commission,
        accident_fund,
        driver_payout,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal_macros::dec;

    fn cfg(per_km: Decimal, commission: Decimal) -> PricingConfig {
        PricingConfig {
            per_km_rate: per_km,
            commission_rate: commission,
        }
    }

    #[test]
    fn basic_two_wheeler_fare() {
        // 5 km at NPR 20/km, no surge => 100. Commission 10% => 10, fund 1% => 1.
        let q = quote_fare(VehicleClass::TwoWheeler, dec!(5), dec!(1.0), cfg(dec!(20), dec!(0.10)));
        assert_eq!(q.fare, Money::from_decimal(dec!(100.00)));
        assert_eq!(q.commission, Money::from_decimal(dec!(10.00)));
        assert_eq!(q.accident_fund, Money::from_decimal(dec!(1.00)));
        assert_eq!(q.driver_payout, Money::from_decimal(dec!(89.00)));
    }

    #[test]
    fn minimum_distance_is_enforced() {
        // A 0.5 km ride is billed as 2 km.
        let q = quote_fare(VehicleClass::TwoWheeler, dec!(0.5), dec!(1.0), cfg(dec!(25), dec!(0.10)));
        assert_eq!(q.billable_distance_km, dec!(2));
        assert_eq!(q.fare, Money::from_decimal(dec!(50.00))); // 2 * 25
    }

    #[test]
    fn per_km_rate_cannot_exceed_legal_cap() {
        // Admin tries NPR 999/km on a two-wheeler; clamps to 25.
        let q = quote_fare(VehicleClass::TwoWheeler, dec!(10), dec!(1.0), cfg(dec!(999), dec!(0.10)));
        assert_eq!(q.effective_per_km_rate, dec!(25));
        assert_eq!(q.fare, Money::from_decimal(dec!(250.00)));
    }

    #[test]
    fn surge_cannot_exceed_20_percent() {
        // Admin/engine proposes 3x surge; clamps to 1.20.
        let q = quote_fare(VehicleClass::FourWheeler, dec!(10), dec!(3.0), cfg(dec!(55), dec!(0.10)));
        assert_eq!(q.effective_surge, dec!(1.20));
        // 10 km * 55 * 1.20 = 660
        assert_eq!(q.fare, Money::from_decimal(dec!(660.00)));
    }

    #[test]
    fn commission_cannot_exceed_10_percent() {
        // Admin tries 50% commission; clamps to 10%.
        let q = quote_fare(VehicleClass::TwoWheeler, dec!(4), dec!(1.0), cfg(dec!(25), dec!(0.50)));
        // fare = 100; commission clamped to 10
        assert_eq!(q.commission, Money::from_decimal(dec!(10.00)));
    }

    #[test]
    fn payout_is_fare_minus_commission_and_fund() {
        let q = quote_fare(VehicleClass::TwoWheeler, dec!(4), dec!(1.0), cfg(dec!(25), dec!(0.10)));
        assert_eq!(q.fare, q.commission + q.accident_fund + q.driver_payout);
    }
}
