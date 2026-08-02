//! Wallet writes for payment operations now live in `saarathi_core::wallet` (the
//! single source of truth shared with rides' settlement path). Re-exported here
//! so `crate::wallet::*` call sites are unchanged. The partner-ledger append is
//! the shared hash-chain writer in `saarathi_core::partner_ledger`.

pub use saarathi_core::partner_ledger::append as partner_ledger_append;
pub use saarathi_core::wallet::{
    credit_driver, credit_rider, log_driver_payout, log_driver_refund, rider_balance,
};
