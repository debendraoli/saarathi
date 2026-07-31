//! Money — NPR amounts as fixed-precision decimals.
//!
//! Money is **never** an `f64`. All fare, commission, and ledger math uses
//! [`rust_decimal::Decimal`] so we never accumulate binary floating-point error
//! on legally-reported financial values.

use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use std::fmt;
use std::ops::{Add, Mul, Sub};

/// A monetary amount in Nepalese Rupees (NPR).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Money(Decimal);

impl Money {
    pub const ZERO: Money = Money(Decimal::ZERO);

    /// Construct from a raw [`Decimal`] amount of rupees.
    pub const fn from_decimal(amount: Decimal) -> Self {
        Money(amount)
    }

    /// Construct from a whole number of rupees.
    pub fn from_rupees(rupees: i64) -> Self {
        Money(Decimal::from(rupees))
    }

    /// The underlying decimal amount.
    pub fn amount(&self) -> Decimal {
        self.0
    }

    /// Multiply by a dimensionless rate (e.g. a commission percentage).
    pub fn scale(&self, rate: Decimal) -> Money {
        Money(self.0 * rate)
    }

    /// Round to 2 decimal places (paisa) using banker's rounding, for display
    /// and for amounts written to the ledger.
    pub fn round_paisa(&self) -> Money {
        Money(self.0.round_dp(2))
    }

    pub fn is_negative(&self) -> bool {
        self.0.is_sign_negative() && !self.0.is_zero()
    }

    pub fn max(self, other: Money) -> Money {
        if self.0 >= other.0 {
            self
        } else {
            other
        }
    }
}

impl Add for Money {
    type Output = Money;
    fn add(self, rhs: Money) -> Money {
        Money(self.0 + rhs.0)
    }
}

impl Sub for Money {
    type Output = Money;
    fn sub(self, rhs: Money) -> Money {
        Money(self.0 - rhs.0)
    }
}

impl Mul<Decimal> for Money {
    type Output = Money;
    fn mul(self, rhs: Decimal) -> Money {
        Money(self.0 * rhs)
    }
}

impl fmt::Display for Money {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "NPR {}", self.0.round_dp(2))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal_macros::dec;

    #[test]
    fn add_and_sub() {
        assert_eq!(
            Money::from_rupees(10) + Money::from_rupees(5),
            Money::from_rupees(15)
        );
        assert_eq!(
            Money::from_rupees(10) - Money::from_rupees(5),
            Money::from_rupees(5)
        );
    }

    #[test]
    fn scale_and_round() {
        let fare = Money::from_rupees(100);
        assert_eq!(fare.scale(dec!(0.10)), Money::from_decimal(dec!(10.0)));
        assert_eq!(
            Money::from_decimal(dec!(10.005)).round_paisa(),
            Money::from_decimal(dec!(10.00))
        );
    }
}
