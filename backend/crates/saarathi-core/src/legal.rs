//! Legally-mandated caps from the **Digital Mobility Service Operation
//! Standards, 2082 (2026)**.
//!
//! These constants are the *only* place these numbers may live. Rates *within*
//! these caps are runtime config set from the admin dashboard; these ceilings
//! are compiled-in and clamp every fare **after** config is applied. See
//! `../../../AGENTS.md` (Golden rules).

use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use serde::{Deserialize, Serialize};

/// Vehicle class — determines the per-km fare ceiling.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VehicleClass {
    /// Two-wheeler (motorbike / scooter).
    TwoWheeler,
    /// Three-wheeler (auto-rickshaw / tempo).
    ThreeWheeler,
    /// Four-wheeler (car).
    FourWheeler,
}

/// Maximum fare per kilometre, in NPR, by vehicle class.
pub const TWO_WHEELER_PER_KM_CAP: Decimal = dec!(25);
/// NOTE: the 2082 standard lists two- and four-wheeler caps; the three-wheeler
/// ceiling here is an interim value (between the two) pending the DoTM figure.
pub const THREE_WHEELER_PER_KM_CAP: Decimal = dec!(40);
pub const FOUR_WHEELER_PER_KM_CAP: Decimal = dec!(55);

/// Minimum billable distance: fares are computed for at least a 2 km ride.
pub const MIN_DISTANCE_KM: Decimal = dec!(2);

/// Maximum dynamic surcharge multiplier (night / weather / wait): +20%.
pub const MAX_SURGE_MULTIPLIER: Decimal = dec!(1.20);
pub const NO_SURGE_MULTIPLIER: Decimal = dec!(1.00);

/// Maximum platform commission: 10% of fare (≥90% to the driver).
pub const MAX_COMMISSION_RATE: Decimal = dec!(0.10);

/// Accident-fund levy: 1% of every fare.
pub const ACCIDENT_FUND_RATE: Decimal = dec!(0.01);

impl VehicleClass {
    /// The per-kilometre fare ceiling for this vehicle class.
    pub const fn per_km_cap(self) -> Decimal {
        match self {
            VehicleClass::TwoWheeler => TWO_WHEELER_PER_KM_CAP,
            VehicleClass::ThreeWheeler => THREE_WHEELER_PER_KM_CAP,
            VehicleClass::FourWheeler => FOUR_WHEELER_PER_KM_CAP,
        }
    }
}
