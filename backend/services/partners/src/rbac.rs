//! Partner membership resolution + capability checks (text roles, shared DB).

use crate::error::{AppError, AppResult};
use saarathi_core::api::ErrorCode;
use saarathi_core::domain::partner_roles as pr;
use uuid::Uuid;

/// The caller's active partner role, or 403 if they aren't an active member of an
/// active partner.
pub async fn member_role(db: &sqlx::PgPool, user_id: Uuid, partner_id: Uuid) -> AppResult<String> {
    let row: Option<(String, String)> = sqlx::query_as(
        "SELECT pm.role::text, p.status::text FROM partner_members pm \
         JOIN partners p ON p.id = pm.partner_id \
         WHERE pm.partner_id = $1 AND pm.user_id = $2 AND pm.status = 'active'",
    )
    .bind(partner_id)
    .bind(user_id)
    .fetch_optional(db)
    .await?;
    let (role, status) = row.ok_or(AppError::Forbidden)?;
    if status != "active" {
        return Err(AppError::forbidden(
            ErrorCode::PartnerSuspended,
            "partner is not active",
        ));
    }
    Ok(role)
}

pub async fn require_member(db: &sqlx::PgPool, user_id: Uuid, partner_id: Uuid) -> AppResult<()> {
    member_role(db, user_id, partner_id).await.map(|_| ())
}

/// Manage members (invite / set role / remove): owner / admin.
pub fn can_manage_members(role: &str) -> bool {
    matches!(role, pr::OWNER | pr::ADMIN)
}

/// Add / release / suspend fleet drivers + riders: owner / admin / manager.
pub fn can_manage_drivers(role: &str) -> bool {
    matches!(role, pr::OWNER | pr::ADMIN | pr::MANAGER)
}

/// Money actions (topup / payout): owner / admin / finance.
pub fn can_manage_money(role: &str) -> bool {
    matches!(role, pr::OWNER | pr::ADMIN | pr::FINANCE)
}

/// Campaign actions: owner / admin / manager.
pub fn can_manage_campaigns(role: &str) -> bool {
    matches!(role, pr::OWNER | pr::ADMIN | pr::MANAGER)
}

pub fn valid_partner_role(s: &str) -> bool {
    matches!(
        s,
        pr::OWNER
            | pr::ADMIN
            | pr::MANAGER
            | pr::DISPATCHER
            | pr::FINANCE
            | pr::SUPPORT
            | pr::VIEWER
    )
}
