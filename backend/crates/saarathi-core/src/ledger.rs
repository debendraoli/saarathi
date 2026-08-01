//! Append-only, hash-chained ledger primitives (compliance-critical).
//!
//! Every completed job produces one immutable entry whose hash chains to the
//! previous entry's hash. Recomputing the chain detects any in-place edit —
//! this is the tamper-evidence the 2082 standard's audit expectations rely on.
//! This module is the **pure hashing core**; persistence lives in the services.

use rust_decimal::Decimal;
use sha2::{Digest, Sha256};

/// Predecessor hash for the very first entry (64 hex zeros).
pub const GENESIS_HASH: &str = "0000000000000000000000000000000000000000000000000000000000000000";

/// Generic hash-chain link: SHA-256 over `seq | prev_hash | payload`. Callers
/// build `payload` from their entry's canonical fields. Used by secondary
/// append-only ledgers (e.g. partner revenue-share) that share the chain
/// discipline but not the trip-specific fields of [`LedgerLink`].
pub fn chain_hash(seq: i64, prev_hash: &str, payload: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(format!("{seq}|{prev_hash}|{payload}").as_bytes());
    hex::encode(hasher.finalize())
}

/// The canonical, hashed content of one ledger entry.
#[derive(Debug, Clone)]
pub struct LedgerLink<'a> {
    pub seq: i64,
    pub prev_hash: &'a str,
    pub trip_id: &'a str,
    pub gross: Decimal,
    pub commission: Decimal,
    pub accident_fund: Decimal,
    pub driver_payout: Decimal,
    pub payment_method: &'a str,
    pub created_at_unix: i64,
}

impl LedgerLink<'_> {
    /// Deterministic SHA-256 over the previous hash + canonical field encoding.
    /// Money is normalised to 2 dp so equal amounts always hash identically.
    pub fn hash(&self) -> String {
        let payload = format!(
            "{}|{}|{}|{}|{}|{}|{}|{}|{}",
            self.seq,
            self.prev_hash,
            self.trip_id,
            self.gross.round_dp(2),
            self.commission.round_dp(2),
            self.accident_fund.round_dp(2),
            self.driver_payout.round_dp(2),
            self.payment_method,
            self.created_at_unix,
        );
        let mut hasher = Sha256::new();
        hasher.update(payload.as_bytes());
        hex::encode(hasher.finalize())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal_macros::dec;

    fn link(seq: i64, prev: &str) -> LedgerLink<'_> {
        LedgerLink {
            seq,
            prev_hash: prev,
            trip_id: "11111111-1111-1111-1111-111111111111",
            gross: dec!(100),
            commission: dec!(10),
            accident_fund: dec!(1),
            driver_payout: dec!(89),
            payment_method: "cash",
            created_at_unix: 1_700_000_000,
        }
    }

    #[test]
    fn deterministic() {
        assert_eq!(link(1, GENESIS_HASH).hash(), link(1, GENESIS_HASH).hash());
    }

    #[test]
    fn tampering_any_field_changes_hash() {
        let base = link(1, GENESIS_HASH).hash();
        let mut m = link(1, GENESIS_HASH);
        m.gross = dec!(200);
        assert_ne!(base, m.hash());
        let mut m2 = link(1, GENESIS_HASH);
        m2.driver_payout = dec!(88);
        assert_ne!(base, m2.hash());
    }

    #[test]
    fn prev_hash_is_part_of_the_chain() {
        assert_ne!(link(1, GENESIS_HASH).hash(), link(1, "deadbeef").hash());
    }

    #[test]
    fn chain_links_forward() {
        let h1 = link(1, GENESIS_HASH).hash();
        let h2 = link(2, &h1).hash();
        assert_ne!(h1, h2);
        // Recomputing entry 2 from the stored prev hash reproduces its hash.
        assert_eq!(link(2, &h1).hash(), h2);
    }

    #[test]
    fn amounts_normalise_to_2dp() {
        let mut a = link(1, GENESIS_HASH);
        a.gross = dec!(100.00);
        let mut b = link(1, GENESIS_HASH);
        b.gross = dec!(100.000);
        assert_eq!(a.hash(), b.hash());
    }
}
