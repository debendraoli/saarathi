//! The trip/delivery completion settlement — the single money-settlement path
//! shared by ride completion (`routes::rides::update_status`) and parcel delivery
//! (`routes::delivery`). On first completion it appends the immutable ledger
//! entry, settles the fare/fee, and runs driver incentives + fleet revenue-share.

use crate::error::AppResult;
use crate::state::AppState;
use rust_decimal::Decimal;
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

/// The money facts needed to settle a completed trip or delivery.
pub struct Completion {
    pub rider_id: Uuid,
    pub driver_id: Option<Uuid>,
    pub gross_fare: Decimal,
    pub commission: Decimal,
    pub accident_fund: Decimal,
    pub driver_payout: Decimal,
    pub final_fare: Decimal,
    pub payment_method: String,
    pub vehicle_class: String,
}

/// Append the immutable ledger entry + settle the wallet on first completion.
/// The caller owns `tx` (rides settles inside the trip tx; delivery inside the
/// POD tx), and must have already flipped the trip's status to `completed`.
pub async fn on_completion(
    st: &AppState,
    tx: &mut Transaction<'_, Postgres>,
    trip_id: Uuid,
    m: &Completion,
) -> AppResult<()> {
    // A driver on an active subscription pass pays 0% commission (keeps 100%,
    // minus the legally-mandatory 1% accident fund).
    let (commission, driver_payout) = match m.driver_id {
        Some(did) if crate::payments::has_active_pass(&mut *tx, did).await? => {
            (Decimal::ZERO, m.gross_fare - m.accident_fund)
        }
        _ => (m.commission, m.driver_payout),
    };
    sqlx::query("UPDATE trips SET commission = $2, driver_payout = $3 WHERE id = $1")
        .bind(trip_id)
        .bind(commission)
        .bind(driver_payout)
        .execute(&mut **tx)
        .await?;
    crate::ledger::append(
        &mut *tx,
        crate::ledger::NewEntry {
            trip_id,
            driver_id: m.driver_id,
            gross: m.gross_fare,
            commission,
            accident_fund: m.accident_fund,
            driver_payout,
            payment_method: m.payment_method.clone(),
        },
    )
    .await?;
    // Settle the fare/fee: wallet from rider credits, corporate from the company
    // wallet; cash is collected in person. The driver split is unaffected.
    match m.payment_method.as_str() {
        "wallet" => {
            crate::payments::debit_rider(
                &mut *tx,
                m.rider_id,
                m.final_fare,
                "payment",
                Some(trip_id),
            )
            .await?;
        }
        "corporate" => {
            crate::partner_ledger::charge_corporate_ride(
                &mut *tx,
                m.rider_id,
                trip_id,
                m.final_fare,
            )
            .await?;
        }
        _ => {}
    }
    // Driver-side campaign incentive (platform-funded) + fleet revenue-share.
    if let Some(did) = m.driver_id {
        let _ = crate::bonus::grant_driver_bonus(
            &mut *tx,
            &st.db,
            did,
            trip_id,
            m.gross_fare,
            &m.vehicle_class,
        )
        .await?;
        let _ = crate::partner_ledger::accrue_commission_share(
            &mut *tx,
            did,
            trip_id,
            m.gross_fare,
            commission,
        )
        .await?;
    }
    Ok(())
}
