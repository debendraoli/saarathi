//! `saarathi-core` — shared domain primitives.
//!
//! This crate holds the pieces that must be identical across every service:
//! money handling, the legally-mandated caps, and the pricing clamp that
//! enforces the **Digital Mobility Service Operation Standards, 2082**.
//!
//! See `../../../AGENTS.md` for the golden rules these modules implement.

pub mod legal;
pub mod money;
pub mod pricing;

pub use money::Money;
