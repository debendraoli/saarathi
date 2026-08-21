//! The wallet/credit helpers used by the trip-settlement path now live in
//! `saarathi_core::wallet` (the single source of truth shared with
//! `saarathi-payments`). Re-exported here so `crate::payments::*` call sites are
//! unchanged. `PaymentProvider` lives in `saarathi_core::payments`.

pub use saarathi_core::wallet::{
    credit_driver_wallet, credit_rider, debit_driver_wallet, debit_rider, driver_credit_balance,
    rider_balance,
};
