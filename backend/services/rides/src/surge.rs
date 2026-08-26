//! Dynamic surge — the raw multiplier proposed to the pricing engine.
//!
//! Two independent signals, combined by taking the max:
//!   1. **Time windows** — dashboard-configured surcharge windows (rush hour,
//!      late night, market day) in `surge_windows`.
//!   2. **Supply scarcity** — when few drivers are online near the pickup, nudge
//!      the fare up to pull supply in.
//!
//! Whatever this returns, `saarathi_core::pricing::quote_fare` hard-clamps it to
//! the legal +20% ceiling — surge can never breach the law.

use crate::flags;
use crate::state::AppState;
use chrono::{Datelike, FixedOffset, TimeZone, Timelike, Utc};
use rust_decimal::Decimal;
use rust_decimal_macros::dec;

/// Nepal Time is UTC+5:45.
const NPT_OFFSET_SECS: i32 = 5 * 3600 + 45 * 60;

fn npt_now() -> chrono::DateTime<FixedOffset> {
    let tz = FixedOffset::east_opt(NPT_OFFSET_SECS).expect("valid offset");
    tz.from_utc_datetime(&Utc::now().naive_utc())
}

/// Highest active time-window multiplier for the current local time + vehicle.
async fn time_window_multiplier(st: &AppState, vclass: &str) -> Decimal {
    let now = npt_now();
    let minute = (now.hour() * 60 + now.minute()) as i32;
    let bit = 1_i32 << now.weekday().num_days_from_sunday(); // bit0=Sun … bit6=Sat

    let rows: Vec<(i32, i32, Decimal)> = sqlx::query_as(
        "SELECT start_minute, end_minute, multiplier FROM surge_windows \
         WHERE active = true AND (days_mask & $1) <> 0 \
           AND (vehicle_class IS NULL OR vehicle_class = $2)",
    )
    .bind(bit)
    .bind(vclass)
    .fetch_all(&st.db)
    .await
    .unwrap_or_default();

    let mut best = dec!(1.0);
    for (start, end, mult) in rows {
        let active = if start <= end {
            minute >= start && minute < end
        } else {
            // window wraps past midnight (e.g. 22:00 → 05:00)
            minute >= start || minute < end
        };
        if active && mult > best {
            best = mult;
        }
    }
    best
}

/// Supply-scarcity surge: when a *handful* of drivers are online near the
/// pickup, nudge the fare up to pull more supply in. Zero nearby drivers means
/// there is no supply to court (and no point punishing the rider), so no surge.
pub fn supply_multiplier(nearby: usize) -> Decimal {
    match nearby {
        1 => dec!(1.15),
        2 => dec!(1.10),
        3 => dec!(1.05),
        // 0 (nothing to incentivise) or plenty of drivers ⇒ no supply surge.
        _ => dec!(1.0),
    }
}

/// The raw surge multiplier to hand to the pricing clamp. Returns 1.0 when the
/// surge feature flag is off. `nearby` is the caller's own already-computed
/// driver count (see `dispatch::nearby_count`) — callers that also need that
/// count for another purpose (e.g. gating the booking button on driver
/// availability) compute it once and pass it in here, rather than this
/// function silently re-querying it.
pub async fn effective_multiplier(st: &AppState, vclass: &str, nearby: usize) -> Decimal {
    if !flags::is_enabled(st, flags::SURGE, true).await {
        return dec!(1.0);
    }
    let by_time = time_window_multiplier(st, vclass).await;
    by_time.max(supply_multiplier(nearby))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn supply_surge_decreases_with_more_drivers() {
        assert_eq!(supply_multiplier(0), dec!(1.0));
        assert_eq!(supply_multiplier(1), dec!(1.15));
        assert_eq!(supply_multiplier(2), dec!(1.10));
        assert_eq!(supply_multiplier(9), dec!(1.0));
    }
}
