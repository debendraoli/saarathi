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
use saarathi_core::legal::VehicleClass;
use saarathi_core::pricing::{quote_fare, PricingConfig};
use serde::Serialize;

#[derive(sqlx::FromRow)]
struct PromoRow {
    kind: String,
    value: Decimal,
    min_fare: Decimal,
    max_discount: Option<Decimal>,
    vehicle_class: Option<String>,
    usage_limit: Option<i32>,
    used_count: i32,
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
    /// Feedback when a promo code was supplied but could not be applied.
    pub note: Option<String>,
    pub currency: &'static str,
}

pub fn parse_vehicle_class(s: &str) -> AppResult<VehicleClass> {
    match s {
        "two_wheeler" => Ok(VehicleClass::TwoWheeler),
        "four_wheeler" => Ok(VehicleClass::FourWheeler),
        other => Err(AppError::BadRequest(format!(
            "unknown vehicle class '{other}'"
        ))),
    }
}

fn class_str(v: VehicleClass) -> &'static str {
    match v {
        VehicleClass::TwoWheeler => "two_wheeler",
        VehicleClass::FourWheeler => "four_wheeler",
    }
}

pub async fn estimate(
    st: &AppState,
    origin: LatLng,
    dest: LatLng,
    vehicle_class: &str,
    code: Option<&str>,
) -> AppResult<(Estimate, RouteResult)> {
    let vclass = parse_vehicle_class(vehicle_class)?;
    let route = st.router.route(origin, dest).await;

    let per_km = match vclass {
        VehicleClass::TwoWheeler => st.config.two_wheeler_per_km,
        VehicleClass::FourWheeler => st.config.four_wheeler_per_km,
    };
    let quote = quote_fare(
        vclass,
        route.distance_km,
        dec!(1.0),
        PricingConfig {
            per_km_rate: per_km,
            commission_rate: st.config.commission_rate,
        },
    );
    let gross = quote.fare.amount();

    let (discount_code, discount_amount, note) = match code {
        Some(c) if !c.trim().is_empty() => {
            match apply_rider_discount(st, c.trim(), gross, vclass).await {
                Ok(amount) => (Some(c.trim().to_string()), amount, None),
                Err(msg) => (None, Decimal::ZERO, Some(msg)),
            }
        }
        _ => (None, Decimal::ZERO, None),
    };

    let final_fare = (gross - discount_amount).max(Decimal::ZERO);

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
            note,
            currency: "NPR",
        },
        route,
    ))
}

/// Returns the discount amount, or a human-readable reason it couldn't apply.
async fn apply_rider_discount(
    st: &AppState,
    code: &str,
    gross: Decimal,
    vclass: VehicleClass,
) -> Result<Decimal, String> {
    let row: Option<PromoRow> = sqlx::query_as(
        "SELECT kind::text, value, min_fare, max_discount, vehicle_class, usage_limit, used_count \
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
        kind,
        value,
        min_fare,
        max_discount,
        vehicle_class: vclass_filter,
        usage_limit,
        used_count,
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
