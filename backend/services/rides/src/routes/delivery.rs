//! Parcel delivery (Phase 3a) — a delivery is a `trip` with `trip_type='delivery'`
//! plus a `parcel_details` extension. It reuses the ride dispatch, tracking,
//! ledger and settlement plumbing; only the parcel-specific booking, pricing,
//! and proof-of-delivery (OTP + photo + COD remittance) live here.

use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::models::{Trip, TRIP_COLS};
use crate::routing::{LatLng, RouteProfile};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{routing::post, Json, Router};
use rust_decimal::Decimal;
use saarathi_core::api::ErrorCode;
use saarathi_core::domain::roles;
use saarathi_core::money::Money;
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/delivery/estimate", post(estimate))
        .route("/v1/delivery/parcels", post(book).get(list_mine))
        .route("/v1/delivery/parcels/{id}/deliver", post(deliver))
}

fn valid_tier(t: &str) -> bool {
    matches!(t, "envelope" | "small" | "medium")
}

/// Delivery fee = base + distance × per-km + size-tier surcharge + fragile
/// surcharge. Config-driven (not bound by the ride per-km caps; see doc 08 §5.2).
fn delivery_fee(st: &AppState, distance_km: Decimal, size_tier: &str, fragile: bool) -> Decimal {
    let tier = match size_tier {
        "small" => st.config.delivery_tier_small,
        "medium" => st.config.delivery_tier_medium,
        _ => Decimal::ZERO,
    };
    let fragile = if fragile {
        st.config.delivery_fragile_surcharge
    } else {
        Decimal::ZERO
    };
    let fee =
        st.config.delivery_base_fare + distance_km * st.config.delivery_per_km + tier + fragile;
    fee.round_dp(2)
}

#[derive(Deserialize)]
struct EstimateReq {
    origin: LatLng,
    dest: LatLng,
    size_tier: String,
    #[serde(default)]
    fragile: bool,
}

async fn estimate(
    State(st): State<AppState>,
    _auth: AuthUser,
    Json(b): Json<EstimateReq>,
) -> AppResult<Json<Value>> {
    if !valid_tier(&b.size_tier) {
        return Err(AppError::BadRequest(
            "size_tier must be 'envelope', 'small', or 'medium'".into(),
        ));
    }
    let route = st
        .router
        .route_path(&[b.origin, b.dest], RouteProfile::Motorcycle)
        .await;
    let fee = delivery_fee(&st, route.distance_km, &b.size_tier, b.fragile);
    let (commission, accident_fund, driver_payout) =
        saarathi_core::pricing::split_fare(Money::from_decimal(fee), st.config.commission_rate);
    Ok(Json(json!({
        "distance_km": route.distance_km,
        "duration_secs": route.duration_secs,
        "delivery_fee": fee,
        "commission": commission.amount(),
        "accident_fund": accident_fund.amount(),
        "driver_payout": driver_payout.amount(),
        "size_tier": b.size_tier,
        "fragile": b.fragile,
    })))
}

#[derive(Deserialize)]
struct BookReq {
    origin: LatLng,
    dest: LatLng,
    size_tier: String,
    recipient_name: String,
    recipient_phone: String,
    #[serde(default)]
    declared_value: Decimal,
    #[serde(default)]
    fragile: bool,
    /// Cash to collect from the recipient (goods payment), remitted to the sender.
    #[serde(default)]
    cod_amount: Decimal,
    #[serde(default)]
    pickup_note: Option<String>,
    /// How the sender pays the delivery *fee*: 'cash' (default) or 'wallet'.
    #[serde(default)]
    payment_method: Option<String>,
}

async fn book(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(b): Json<BookReq>,
) -> AppResult<Json<Value>> {
    if !valid_tier(&b.size_tier) {
        return Err(AppError::BadRequest(
            "size_tier must be 'envelope', 'small', or 'medium'".into(),
        ));
    }
    if b.recipient_name.trim().is_empty() || b.recipient_phone.trim().is_empty() {
        return Err(AppError::BadRequest(
            "recipient_name and recipient_phone are required".into(),
        ));
    }
    if b.cod_amount < Decimal::ZERO || b.declared_value < Decimal::ZERO {
        return Err(AppError::BadRequest(
            "cod_amount and declared_value must be non-negative".into(),
        ));
    }
    let method = b.payment_method.as_deref().unwrap_or("cash");
    if !matches!(method, "cash" | "wallet") {
        return Err(AppError::bad(
            ErrorCode::InvalidPaymentMethod,
            "payment_method must be 'cash' or 'wallet'",
        ));
    }

    let route = st
        .router
        .route_path(&[b.origin, b.dest], RouteProfile::Motorcycle)
        .await;
    let fee = delivery_fee(&st, route.distance_km, &b.size_tier, b.fragile);
    let (commission, accident_fund, driver_payout) =
        saarathi_core::pricing::split_fare(Money::from_decimal(fee), st.config.commission_rate);

    // Prepaid fee: a wallet-paid delivery needs enough sender credits up front.
    if method == "wallet" {
        let balance = crate::payments::rider_balance(&st.db, claims.sub).await?;
        if balance < fee {
            return Err(AppError::bad(
                ErrorCode::InsufficientCredits,
                "insufficient credits for the delivery fee",
            ));
        }
    }

    // A short recipient hand-off code. Dev-grade; production uses a CSPRNG.
    let otp = format!("{:04}", (Uuid::new_v4().as_u128() % 10000) as u32);

    let mut tx = st.db.begin().await?;
    let trip: Trip = sqlx::query_as(&format!(
        "INSERT INTO trips (rider_id, trip_type, vehicle_class, origin_lat, origin_lng, dest_lat, dest_lng, \
            distance_km, duration_secs, gross_fare, discount_amount, final_fare, commission, \
            accident_fund, driver_payout, payment_method) \
         VALUES ($1,'delivery','two_wheeler',$2,$3,$4,$5,$6,$7,$8,0,$8,$9,$10,$11,$12) RETURNING {TRIP_COLS}"
    ))
    .bind(claims.sub)
    .bind(b.origin.lat)
    .bind(b.origin.lng)
    .bind(b.dest.lat)
    .bind(b.dest.lng)
    .bind(route.distance_km)
    .bind(route.duration_secs)
    .bind(fee)
    .bind(commission.amount())
    .bind(accident_fund.amount())
    .bind(driver_payout.amount())
    .bind(method)
    .fetch_one(&mut *tx)
    .await?;

    sqlx::query(
        "INSERT INTO parcel_details (trip_id, size_tier, recipient_name, recipient_phone, \
            declared_value, fragile, cod_amount, pickup_note, delivery_otp) \
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)",
    )
    .bind(trip.id)
    .bind(&b.size_tier)
    .bind(b.recipient_name.trim())
    .bind(b.recipient_phone.trim())
    .bind(b.declared_value)
    .bind(b.fragile)
    .bind(b.cod_amount)
    .bind(&b.pickup_note)
    .bind(&otp)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    // Kick dispatch; drivers who opted into 'delivery' jobs get the offer.
    tokio::spawn({
        let st = st.clone();
        let trip_id = trip.id;
        async move {
            let _ = crate::dispatch::dispatch_trip(&st, trip_id).await;
        }
    });

    Ok(Json(json!({
        "trip": trip,
        "delivery_fee": fee,
        "cod_amount": b.cod_amount,
        "delivery_otp": otp,
    })))
}

#[derive(sqlx::FromRow)]
struct DeliveryTrip {
    rider_id: Uuid,
    driver_id: Option<Uuid>,
    trip_type: String,
    status: String,
    vehicle_class: String,
    gross_fare: Decimal,
    commission: Decimal,
    accident_fund: Decimal,
    driver_payout: Decimal,
    final_fare: Decimal,
    payment_method: String,
}

#[derive(Deserialize)]
struct DeliverReq {
    photo_key: String,
    otp: String,
    #[serde(default)]
    recipient: Option<String>,
}

/// Proof-of-delivery: the driver confirms the recipient's OTP, stores the POD
/// photo, remits any COD cash to the sender's wallet, and settles the delivery
/// fee through the shared completion path — all atomically.
async fn deliver(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
    Json(b): Json<DeliverReq>,
) -> AppResult<Json<Value>> {
    if claims.role != roles::DRIVER {
        return Err(AppError::Forbidden);
    }
    if b.photo_key.trim().is_empty() {
        return Err(AppError::BadRequest(
            "photo_key (proof photo) is required".into(),
        ));
    }

    let mut tx = st.db.begin().await?;
    let m: Option<DeliveryTrip> = sqlx::query_as(
        "SELECT rider_id, driver_id, trip_type::text AS trip_type, status::text AS status, \
                vehicle_class, gross_fare, commission, accident_fund, driver_payout, final_fare, \
                payment_method FROM trips WHERE id = $1 FOR UPDATE",
    )
    .bind(id)
    .fetch_optional(&mut *tx)
    .await?;
    let m = m.ok_or(AppError::NotFound)?;
    if m.trip_type != "delivery" {
        return Err(AppError::BadRequest("not a delivery".into()));
    }
    if m.driver_id != Some(claims.sub) {
        return Err(AppError::Forbidden);
    }
    if m.status != "in_progress" {
        return Err(AppError::BadRequest(
            "parcel must be picked up (in_progress) before delivery".into(),
        ));
    }

    let parcel: Option<(String, Decimal, bool)> = sqlx::query_as(
        "SELECT delivery_otp, cod_amount, cod_remitted FROM parcel_details WHERE trip_id = $1 FOR UPDATE",
    )
    .bind(id)
    .fetch_optional(&mut *tx)
    .await?;
    let (otp, cod_amount, cod_remitted) = parcel.ok_or(AppError::NotFound)?;
    if otp != b.otp {
        return Err(AppError::bad(
            ErrorCode::Validation,
            "invalid delivery code",
        ));
    }

    sqlx::query("UPDATE trips SET status = 'completed', completed_at = now(), updated_at = now() WHERE id = $1")
        .bind(id)
        .execute(&mut *tx)
        .await?;

    crate::settle::on_completion(
        &st,
        &mut tx,
        id,
        &crate::settle::Completion {
            rider_id: m.rider_id,
            driver_id: m.driver_id,
            gross_fare: m.gross_fare,
            commission: m.commission,
            accident_fund: m.accident_fund,
            driver_payout: m.driver_payout,
            final_fare: m.final_fare,
            payment_method: m.payment_method.clone(),
            vehicle_class: m.vehicle_class.clone(),
        },
    )
    .await?;

    // Remit collected COD cash to the sender's wallet. The driver is holding
    // that cash, so it's debited from their earnings (they owe it) — money is
    // conserved: sender +cod, driver −cod.
    let cod_done = if cod_amount > Decimal::ZERO && !cod_remitted {
        crate::payments::credit_rider(
            &mut tx,
            m.rider_id,
            cod_amount,
            "cod_remittance",
            None,
            Some(id),
        )
        .await?;
        crate::payments::debit_driver_wallet(
            &mut tx,
            claims.sub,
            cod_amount,
            "cod_collected",
            &format!("cod:{id}"),
        )
        .await?;
        true
    } else {
        cod_remitted
    };

    sqlx::query(
        "UPDATE parcel_details SET pod_photo_key = $2, pod_recipient = $3, delivered_at = now(), \
            cod_remitted = $4 WHERE trip_id = $1",
    )
    .bind(id)
    .bind(b.photo_key.trim())
    .bind(&b.recipient)
    .bind(cod_done)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    st.hub.publish(
        id,
        json!({ "type": "status", "status": "completed" }).to_string(),
    );

    Ok(Json(json!({
        "delivered": true,
        "delivery_fee": m.final_fare,
        "driver_payout": m.driver_payout,
        "cod_remitted": cod_done,
        "cod_amount": cod_amount,
    })))
}

async fn list_mine(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Vec<Trip>>> {
    let rows: Vec<Trip> = sqlx::query_as(&format!(
        "SELECT {TRIP_COLS} FROM trips WHERE trip_type = 'delivery' AND (rider_id = $1 OR driver_id = $1) \
         ORDER BY created_at DESC LIMIT 100"
    ))
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}
