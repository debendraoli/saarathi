//! Domain string constants shared across services.
//!
//! These are the wire/DB values that recur in role checks, status comparisons,
//! and `.bind(...)` calls. Centralising them here (instead of scattering string
//! literals) makes the vocabulary discoverable and typo-proof. Postgres enum
//! *types* are still enforced in the DB; these mirror their labels for Rust-side
//! logic.

/// Platform user roles (`users.role`).
pub mod roles {
    pub const RIDER: &str = "rider";
    pub const DRIVER: &str = "driver";
    pub const SUPER_ADMIN: &str = "super_admin";
    pub const ADMIN: &str = "admin";
    pub const DISPATCHER: &str = "dispatcher";
    pub const FINANCE: &str = "finance";
    pub const COMPLIANCE: &str = "compliance";
    pub const SUPPORT: &str = "support";
    pub const ANALYST: &str = "analyst";
}

/// Account lifecycle (`users.status`).
pub mod user_status {
    pub const PENDING: &str = "pending";
    pub const ACTIVE: &str = "active";
    pub const SUSPENDED: &str = "suspended";
    pub const BANNED: &str = "banned";
}

/// Partner-scoped roles (`partner_members.role`).
pub mod partner_roles {
    pub const OWNER: &str = "owner";
    pub const ADMIN: &str = "admin";
    pub const MANAGER: &str = "manager";
    pub const DISPATCHER: &str = "dispatcher";
    pub const FINANCE: &str = "finance";
    pub const SUPPORT: &str = "support";
    pub const VIEWER: &str = "viewer";
}

/// How a trip's fare is settled (`trips.payment_method`).
pub mod payment {
    pub const CASH: &str = "cash";
    pub const WALLET: &str = "wallet";
    pub const CORPORATE: &str = "corporate";
}

/// Trip lifecycle (`trips.status`).
pub mod trip_status {
    pub const REQUESTED: &str = "requested";
    pub const ACCEPTED: &str = "accepted";
    pub const ARRIVING: &str = "arriving";
    pub const IN_PROGRESS: &str = "in_progress";
    pub const COMPLETED: &str = "completed";
    pub const CANCELLED: &str = "cancelled";
}

/// In-app notification classes (`notifications.class`).
pub mod notif {
    pub const SAFETY: &str = "safety";
    pub const TRANSACTIONAL: &str = "transactional";
    pub const COMPLIANCE: &str = "compliance";
    pub const MARKETING: &str = "marketing";
    pub const SUPPORT: &str = "support";

    /// Classes that escalate past the inbox to push/SMS.
    pub const CRITICAL: [&str; 4] = [SAFETY, TRANSACTIONAL, COMPLIANCE, SUPPORT];
}

/// Partner-ledger movement kinds (`partner_ledger.kind`).
pub mod partner_ledger_kind {
    pub const COMMISSION_SHARE: &str = "commission_share";
    pub const PROMO_SPEND: &str = "promo_spend";
    pub const TOPUP: &str = "topup";
    pub const PAYOUT: &str = "payout";
    pub const PAYOUT_REVERSAL: &str = "payout_reversal";
    pub const RIDE_CHARGE: &str = "ride_charge";
}

/// Payout settlement lifecycle (`payout_requests.status`, `partner_payouts.status`).
pub mod payout_status {
    pub const PROCESSING: &str = "processing";
    pub const PAID: &str = "paid";
    pub const FAILED: &str = "failed";
}
