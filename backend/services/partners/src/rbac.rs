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

#[cfg(test)]
mod tests {
    use super::*;

    const ALL_ROLES: [&str; 7] = [
        pr::OWNER,
        pr::ADMIN,
        pr::MANAGER,
        pr::DISPATCHER,
        pr::FINANCE,
        pr::SUPPORT,
        pr::VIEWER,
    ];

    #[test]
    fn valid_partner_role_accepts_exactly_the_seven_known_roles() {
        for role in ALL_ROLES {
            assert!(valid_partner_role(role), "{role} should be valid");
        }
        assert!(!valid_partner_role("superadmin"));
        assert!(!valid_partner_role(""));
        assert!(!valid_partner_role("Owner")); // case-sensitive: DB values are lowercase
    }

    #[test]
    fn can_manage_members_is_owner_and_admin_only() {
        for role in ALL_ROLES {
            let expected = matches!(role, "owner" | "admin");
            assert_eq!(can_manage_members(role), expected, "role={role}");
        }
    }

    #[test]
    fn can_manage_drivers_includes_manager_but_not_finance_or_below() {
        for role in ALL_ROLES {
            let expected = matches!(role, "owner" | "admin" | "manager");
            assert_eq!(can_manage_drivers(role), expected, "role={role}");
        }
    }

    #[test]
    fn can_manage_money_is_owner_admin_finance_only() {
        for role in ALL_ROLES {
            let expected = matches!(role, "owner" | "admin" | "finance");
            assert_eq!(can_manage_money(role), expected, "role={role}");
        }
        // The money gate specifically must NOT trust "manager" — a manager
        // can run drivers/campaigns but was never granted a money capability.
        assert!(!can_manage_money(pr::MANAGER));
    }

    #[test]
    fn can_manage_campaigns_matches_can_manage_drivers_gate() {
        // Both capabilities are currently owner/admin/manager — this test
        // exists so a future divergence (e.g. campaigns opened to dispatcher)
        // is a deliberate, visible diff instead of a silent one.
        for role in ALL_ROLES {
            assert_eq!(
                can_manage_campaigns(role),
                can_manage_drivers(role),
                "role={role}"
            );
        }
    }

    #[test]
    fn dispatcher_support_and_viewer_hold_no_management_capability() {
        for role in [pr::DISPATCHER, pr::SUPPORT, pr::VIEWER] {
            assert!(!can_manage_members(role), "role={role}");
            assert!(!can_manage_drivers(role), "role={role}");
            assert!(!can_manage_money(role), "role={role}");
            assert!(!can_manage_campaigns(role), "role={role}");
        }
    }
}
