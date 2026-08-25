//! `saarathi-core` — shared domain primitives.
//!
//! This crate holds the pieces that must be identical across every service:
//! money handling, the legally-mandated caps, and the pricing clamp that
//! enforces the **Digital Mobility Service Operation Standards, 2082**.
//!
//! See `../../../AGENTS.md` for the golden rules these modules implement.

pub mod api;
pub mod authn;
pub mod campaigns;
pub mod domain;
pub mod events;
pub mod geo_h3;
pub mod idempotency;
pub mod ledger;
pub mod legal;
pub mod money;
pub mod partner_ledger;
pub mod payments;
pub mod pelias_index;
pub mod pricing;
pub mod routing;
pub mod wallet;

pub use money::Money;
