//! Row/DTO structs for trips and campaigns.

use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::Serialize;
use sqlx::FromRow;
use uuid::Uuid;

/// Column list for `trips` (enum columns cast to text so we avoid sqlx enum
/// derives). Reused across queries.
pub const TRIP_COLS: &str = "id, rider_id, driver_id, trip_type::text AS trip_type, \
    status::text AS status, vehicle_class, origin_lat, origin_lng, dest_lat, dest_lng, \
    distance_km, duration_secs, gross_fare, discount_code, discount_amount, final_fare, \
    commission, accident_fund, driver_payout, stops, cancel_reason, cancelled_by_role, \
    created_at, accepted_at, completed_at, cancelled_at";

#[derive(Debug, Serialize, FromRow)]
pub struct Trip {
    pub id: Uuid,
    pub rider_id: Uuid,
    pub driver_id: Option<Uuid>,
    pub trip_type: String,
    pub status: String,
    pub vehicle_class: String,
    pub origin_lat: f64,
    pub origin_lng: f64,
    pub dest_lat: f64,
    pub dest_lng: f64,
    pub distance_km: Decimal,
    pub duration_secs: i32,
    pub gross_fare: Decimal,
    pub discount_code: Option<String>,
    pub discount_amount: Decimal,
    pub final_fare: Decimal,
    pub commission: Decimal,
    pub accident_fund: Decimal,
    pub driver_payout: Decimal,
    pub stops: serde_json::Value,
    pub cancel_reason: Option<String>,
    pub cancelled_by_role: Option<String>,
    pub created_at: DateTime<Utc>,
    pub accepted_at: Option<DateTime<Utc>>,
    pub completed_at: Option<DateTime<Utc>>,
    pub cancelled_at: Option<DateTime<Utc>>,
}
