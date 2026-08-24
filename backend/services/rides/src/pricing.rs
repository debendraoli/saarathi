//! Fare estimation: routing distance → legal pricing clamp → optional promo.
//!
//! The legal caps live in `saarathi_core::legal` and are enforced by
//! `saarathi_core::pricing::quote_fare`. Promos are **platform-funded**: the
//! discount reduces what the rider pays, but commission / accident-fund /
//! driver payout are computed on the gross fare, so the driver is never short-changed.

use crate::error::{AppError, AppResult};
use crate::routing::{LatLng, RouteResult};
use crate::state::AppState;
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use saarathi_core::api::ErrorCode;
use saarathi_core::legal::VehicleClass;
use saarathi_core::pricing::{quote_fare, PricingConfig};
use serde::Serialize;
use uuid::Uuid;

#[derive(sqlx::FromRow)]
struct PromoRow {
    id: Uuid,
    kind: String,
    value: Decimal,
    min_fare: Decimal,
    max_discount: Option<Decimal>,
    vehicle_class: Option<String>,
    usage_limit: Option<i32>,
    used_count: i32,
    rules: sqlx::types::Json<Vec<crate::rules::CampaignRule>>,
}

#[derive(Debug, Serialize)]
pub struct Estimate {
    pub vehicle_class: String,
    pub distance_km: Decimal,
    pub duration_secs: i32,
    pub route_source: String,
    pub gross_fare: Decimal,
    pub discount_code: Option<String>,
    pub discount_amount: Decimal,
    pub final_fare: Decimal,
    pub commission: Decimal,
    pub accident_fund: Decimal,
    pub driver_payout: Decimal,
    /// Bounded bargaining band: a rider may propose any fare in [floor, ceiling].
    pub fare_floor: Decimal,
    pub fare_ceiling: Decimal,
    /// The surge multiplier actually applied (already clamped to the legal +20%).
    pub surge_multiplier: Decimal,
    /// Feedback when a promo code was supplied but could not be applied.
    pub note: Option<String>,
    pub currency: &'static str,
}

pub fn parse_vehicle_class(s: &str) -> AppResult<VehicleClass> {
    match s {
        "two_wheeler" => Ok(VehicleClass::TwoWheeler),
        "three_wheeler" => Ok(VehicleClass::ThreeWheeler),
        "four_wheeler" => Ok(VehicleClass::FourWheeler),
        other => Err(AppError::bad(
            ErrorCode::InvalidVehicleClass,
            format!("unknown vehicle class '{other}'"),
        )),
    }
}

/// Splits an already-agreed fare into the same commission/accident-fund/
/// payout/final-fare shape `create()`'s bargaining branch computes — shared
/// so a bid's acceptance (`routes::bidding::accept_bid`) recomputes the
/// money split through this one path rather than a second copy of the math.
/// Returns `(commission, accident_fund, driver_payout, final_fare)`.
pub fn split_agreed_fare(
    agreed: Decimal,
    discount_amount: Decimal,
    commission_rate: Decimal,
) -> (Decimal, Decimal, Decimal, Decimal) {
    let commission = (agreed * commission_rate).round_dp(2);
    let fund = (agreed * dec!(0.01)).round_dp(2);
    let payout = agreed - commission - fund;
    let final_fare = (agreed - discount_amount).max(Decimal::ZERO);
    (commission, fund, payout, final_fare)
}

fn class_str(v: VehicleClass) -> &'static str {
    match v {
        VehicleClass::TwoWheeler => "two_wheeler",
        VehicleClass::ThreeWheeler => "three_wheeler",
        VehicleClass::FourWheeler => "four_wheeler",
    }
}

/// The dashboard-approved rate for this class if one has ever been set
/// (`routes::rates`'s maker-checker flow writes it), else the env-configured
/// default — same "live read, no cache" convention `surge.rs` already uses
/// for its own dashboard-configured pricing inputs.
async fn effective_per_km_rate(st: &AppState, vclass: VehicleClass) -> Decimal {
    let env_default = match vclass {
        VehicleClass::TwoWheeler => st.config.two_wheeler_per_km,
        VehicleClass::ThreeWheeler => st.config.three_wheeler_per_km,
        VehicleClass::FourWheeler => st.config.four_wheeler_per_km,
    };
    sqlx::query_scalar::<_, Decimal>(
        "SELECT per_km_rate FROM fare_rates WHERE vehicle_class = $1",
    )
    .bind(class_str(vclass))
    .fetch_optional(&st.db)
    .await
    .ok()
    .flatten()
    .unwrap_or(env_default)
}

pub async fn estimate(
    st: &AppState,
    user_id: Uuid,
    origin: LatLng,
    dest: LatLng,
    stops: &[LatLng],
    vehicle_class: &str,
    code: Option<&str>,
) -> AppResult<(Estimate, RouteResult)> {
    let vclass = parse_vehicle_class(vehicle_class)?;
    // Fare distance runs origin → each stop → destination, costed per vehicle.
    let mut path = Vec::with_capacity(stops.len() + 2);
    path.push(origin);
    path.extend_from_slice(stops);
    path.push(dest);
    let profile = match vclass {
        VehicleClass::TwoWheeler => crate::routing::RouteProfile::Motorcycle,
        VehicleClass::ThreeWheeler => crate::routing::RouteProfile::Auto,
        VehicleClass::FourWheeler => crate::routing::RouteProfile::Auto,
    };
    let route = st.router.route_path(&path, profile).await;

    let per_km = effective_per_km_rate(st, vclass).await;
    // Dynamic surge (time windows + supply scarcity); the core clamps it to +20%.
    let surge = crate::surge::effective_multiplier(st, vehicle_class, origin).await;
    let quote = quote_fare(
        vclass,
        route.distance_km,
        surge,
        PricingConfig {
            per_km_rate: per_km,
            commission_rate: st.config.commission_rate,
        },
    );
    let gross = quote.fare.amount();

    let (discount_code, discount_amount, note) = match code {
        Some(c) if !c.trim().is_empty() => {
            match apply_rider_discount(st, user_id, c.trim(), gross, vclass).await {
                Ok(amount) => (Some(c.trim().to_string()), amount, None),
                Err(msg) => (None, Decimal::ZERO, Some(msg)),
            }
        }
        // No code supplied — auto-apply whichever active rider offer gives
        // the biggest discount, so redemption needs no code-entry UI at
        // all (offers are just shown, not typed in).
        _ => match auto_pick_rider_discount(st, user_id, gross, vclass).await {
            Some((c, amount)) => (Some(c), amount, None),
            None => (None, Decimal::ZERO, None),
        },
    };

    let final_fare = (gross - discount_amount).max(Decimal::ZERO);

    // Bargaining band: down to a configured fraction of the algorithmic fare,
    // up to the absolute legal ceiling (per-km cap × +20% surge).
    let fare_ceiling = saarathi_core::pricing::legal_ceiling(vclass, route.distance_km);
    let fare_floor = (gross * st.config.bargain_floor_ratio).round_dp(2);

    Ok((
        Estimate {
            vehicle_class: vehicle_class.to_string(),
            distance_km: route.distance_km,
            duration_secs: route.duration_secs,
            route_source: route.source.to_string(),
            gross_fare: gross,
            discount_code,
            discount_amount,
            final_fare,
            commission: quote.commission.amount(),
            accident_fund: quote.accident_fund.amount(),
            driver_payout: quote.driver_payout.amount(),
            fare_floor,
            fare_ceiling,
            surge_multiplier: quote.effective_surge,
            note,
            currency: "NPR",
        },
        route,
    ))
}

/// Returns the discount amount, or a human-readable reason it couldn't apply.
async fn apply_rider_discount(
    st: &AppState,
    user_id: Uuid,
    code: &str,
    gross: Decimal,
    vclass: VehicleClass,
) -> Result<Decimal, String> {
    let row: Option<PromoRow> = sqlx::query_as(
        "SELECT id, kind::text, value, min_fare, max_discount, vehicle_class, usage_limit, \
                used_count, rules \
             FROM campaigns \
             WHERE code = $1 AND audience = 'rider' AND active = true \
               AND (starts_at IS NULL OR starts_at <= now()) \
               AND (ends_at IS NULL OR ends_at >= now())",
    )
    .bind(code)
    .fetch_optional(&st.db)
    .await
    .map_err(|_| "could not validate code".to_string())?;

    let Some(PromoRow {
        id,
        kind,
        value,
        min_fare,
        max_discount,
        vehicle_class: vclass_filter,
        usage_limit,
        used_count,
        rules,
    }) = row
    else {
        return Err("invalid or expired code".into());
    };

    if let Some(vc) = vclass_filter {
        if vc != class_str(vclass) {
            return Err("code not valid for this vehicle type".into());
        }
    }
    if gross < min_fare {
        return Err(format!(
            "minimum fare NPR {min_fare} required for this code"
        ));
    }
    if let Some(limit) = usage_limit {
        if used_count >= limit {
            return Err("code fully redeemed".into());
        }
    }
    // Dynamic rules (new customer, min rides, time window, per-user limit…).
    if !rules.0.is_empty() {
        let ctx = crate::rules::load_context(&st.db, user_id, "rider", id, gross, None).await;
        if !crate::rules::evaluate(&rules.0, &ctx) {
            return Err("you're not eligible for this offer".into());
        }
    }

    let mut discount = match kind.as_str() {
        "percent" => (gross * value / dec!(100)).round_dp(2),
        _ => value,
    };
    if let Some(cap) = max_discount {
        if discount > cap {
            discount = cap;
        }
    }
    if discount > gross {
        discount = gross;
    }
    Ok(discount)
}

#[derive(sqlx::FromRow)]
struct AutoPromoRow {
    id: Uuid,
    code: String,
    kind: String,
    value: Decimal,
    min_fare: Decimal,
    max_discount: Option<Decimal>,
    vehicle_class: Option<String>,
    usage_limit: Option<i32>,
    used_count: i32,
    rules: sqlx::types::Json<Vec<crate::rules::CampaignRule>>,
}

/// Scans every active, in-window rider campaign and picks whichever gives
/// the biggest discount for this fare/vehicle/user — the no-code-needed
/// counterpart to [`apply_rider_discount`]. Offers are surfaced to the
/// rider purely as informational banners; nothing needs to be typed in.
async fn auto_pick_rider_discount(
    st: &AppState,
    user_id: Uuid,
    gross: Decimal,
    vclass: VehicleClass,
) -> Option<(String, Decimal)> {
    let rows: Vec<AutoPromoRow> = sqlx::query_as(
        "SELECT id, code, kind::text, value, min_fare, max_discount, vehicle_class, \
                usage_limit, used_count, rules \
             FROM campaigns \
             WHERE audience = 'rider' AND active = true AND code IS NOT NULL \
               AND (starts_at IS NULL OR starts_at <= now()) \
               AND (ends_at IS NULL OR ends_at >= now())",
    )
    .fetch_all(&st.db)
    .await
    .unwrap_or_default();

    let mut best: Option<(String, Decimal)> = None;
    for row in rows {
        if let Some(vc) = &row.vehicle_class {
            if vc != class_str(vclass) {
                continue;
            }
        }
        if gross < row.min_fare {
            continue;
        }
        if let Some(limit) = row.usage_limit {
            if row.used_count >= limit {
                continue;
            }
        }
        if !row.rules.0.is_empty() {
            let ctx =
                crate::rules::load_context(&st.db, user_id, "rider", row.id, gross, None).await;
            if !crate::rules::evaluate(&row.rules.0, &ctx) {
                continue;
            }
        }
        let mut discount = match row.kind.as_str() {
            "percent" => (gross * row.value / dec!(100)).round_dp(2),
            _ => row.value,
        };
        if let Some(cap) = row.max_discount {
            if discount > cap {
                discount = cap;
            }
        }
        if discount > gross {
            discount = gross;
        }
        if discount <= Decimal::ZERO {
            continue;
        }
        if best.as_ref().is_none_or(|(_, best_amt)| discount > *best_amt) {
            best = Some((row.code, discount));
        }
    }
    best
}
