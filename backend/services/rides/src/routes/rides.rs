//! Ride lifecycle + fare estimate endpoints.

use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::models::{Trip, TRIP_COLS};
use crate::pricing::{self, Estimate};
use crate::routing::LatLng;
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use rust_decimal::Decimal;
use serde::Deserialize;
use serde_json::json;
use uuid::Uuid;

#[derive(sqlx::FromRow)]
struct TripMoney {
    rider_id: Uuid,
    driver_id: Option<Uuid>,
    status: String,
    gross_fare: Decimal,
    commission: Decimal,
    accident_fund: Decimal,
    driver_payout: Decimal,
    payment_method: String,
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/rides/estimate", post(estimate))
        .route("/v1/rides", post(create).get(list_mine))
        .route("/v1/rides/{id}", get(get_trip))
        .route("/v1/rides/{id}/accept", post(accept))
        .route("/v1/rides/{id}/status", post(update_status))
}

#[derive(Deserialize)]
struct RideRequest {
    origin: LatLng,
    dest: LatLng,
    vehicle_class: String,
    #[serde(default)]
    code: Option<String>,
}

async fn estimate(
    State(st): State<AppState>,
    _auth: AuthUser,
    Json(body): Json<RideRequest>,
) -> AppResult<Json<Estimate>> {
    let (est, _route) = pricing::estimate(
        &st,
        body.origin,
        body.dest,
        &body.vehicle_class,
        body.code.as_deref(),
    )
    .await?;
    Ok(Json(est))
}

async fn create(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<RideRequest>,
) -> AppResult<Json<Trip>> {
    let (est, _route) = pricing::estimate(
        &st,
        body.origin,
        body.dest,
        &body.vehicle_class,
        body.code.as_deref(),
    )
    .await?;

    let mut tx = st.db.begin().await?;

    if let Some(code) = &est.discount_code {
        if let Some((cid,)) = sqlx::query_as::<_, (Uuid,)>(
            "SELECT id FROM campaigns WHERE code = $1 AND audience = 'rider' AND active = true",
        )
        .bind(code)
        .fetch_optional(&mut *tx)
        .await?
        {
            sqlx::query("UPDATE campaigns SET used_count = used_count + 1 WHERE id = $1")
                .bind(cid)
                .execute(&mut *tx)
                .await?;
            sqlx::query(
                "INSERT INTO campaign_redemptions (campaign_id, user_id, amount) VALUES ($1, $2, $3)",
            )
            .bind(cid)
            .bind(claims.sub)
            .bind(est.discount_amount)
            .execute(&mut *tx)
            .await?;
        }
    }

    let trip: Trip = sqlx::query_as(&format!(
        "INSERT INTO trips (rider_id, vehicle_class, origin_lat, origin_lng, dest_lat, dest_lng, \
            distance_km, duration_secs, gross_fare, discount_code, discount_amount, final_fare, \
            commission, accident_fund, driver_payout) \
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15) RETURNING {TRIP_COLS}"
    ))
    .bind(claims.sub)
    .bind(&body.vehicle_class)
    .bind(body.origin.lat)
    .bind(body.origin.lng)
    .bind(body.dest.lat)
    .bind(body.dest.lng)
    .bind(est.distance_km)
    .bind(est.duration_secs)
    .bind(est.gross_fare)
    .bind(&est.discount_code)
    .bind(est.discount_amount)
    .bind(est.final_fare)
    .bind(est.commission)
    .bind(est.accident_fund)
    .bind(est.driver_payout)
    .fetch_one(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(Json(trip))
}

async fn accept(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Trip>> {
    if claims.role != "driver" {
        return Err(AppError::Forbidden);
    }
    let trip: Trip = sqlx::query_as(&format!(
        "UPDATE trips SET driver_id = $2, status = 'accepted', accepted_at = now(), updated_at = now() \
         WHERE id = $1 AND status = 'requested' RETURNING {TRIP_COLS}"
    ))
    .bind(id)
    .bind(claims.sub)
    .fetch_optional(&st.db)
    .await?
    .ok_or_else(|| AppError::Conflict("trip is no longer available".into()))?;

    st.hub.publish(
        id,
        json!({ "type": "status", "status": "accepted", "driver_id": claims.sub }).to_string(),
    );
    Ok(Json(trip))
}

#[derive(Deserialize)]
struct StatusRequest {
    status: String,
}

async fn update_status(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
    Json(body): Json<StatusRequest>,
) -> AppResult<Json<Trip>> {
    const ALLOWED: [&str; 4] = ["arriving", "in_progress", "completed", "cancelled"];
    if !ALLOWED.contains(&body.status.as_str()) {
        return Err(AppError::BadRequest("invalid status transition".into()));
    }

    let mut tx = st.db.begin().await?;
    let row: Option<TripMoney> = sqlx::query_as(
        "SELECT rider_id, driver_id, status::text AS status, gross_fare, commission, \
                accident_fund, driver_payout, payment_method \
         FROM trips WHERE id = $1 FOR UPDATE",
    )
    .bind(id)
    .fetch_optional(&mut *tx)
    .await?;
    let m = row.ok_or(AppError::NotFound)?;
    if m.rider_id != claims.sub && m.driver_id != Some(claims.sub) {
        return Err(AppError::Forbidden);
    }

    let ts_col = match body.status.as_str() {
        "completed" => ", completed_at = now()",
        "cancelled" => ", cancelled_at = now()",
        _ => "",
    };
    let trip: Trip = sqlx::query_as(&format!(
        "UPDATE trips SET status = $2::trip_status, updated_at = now(){ts_col} \
         WHERE id = $1 RETURNING {TRIP_COLS}"
    ))
    .bind(id)
    .bind(&body.status)
    .fetch_one(&mut *tx)
    .await?;

    // On first completion, append the immutable ledger entry + settle the wallet.
    if body.status == "completed" && m.status != "completed" {
        crate::ledger::append(
            &mut tx,
            crate::ledger::NewEntry {
                trip_id: id,
                driver_id: m.driver_id,
                gross: m.gross_fare,
                commission: m.commission,
                accident_fund: m.accident_fund,
                driver_payout: m.driver_payout,
                payment_method: m.payment_method,
            },
        )
        .await?;
    }

    tx.commit().await?;

    st.hub.publish(
        id,
        json!({ "type": "status", "status": body.status }).to_string(),
    );
    Ok(Json(trip))
}

async fn get_trip(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Trip>> {
    let trip: Trip = sqlx::query_as(&format!("SELECT {TRIP_COLS} FROM trips WHERE id = $1"))
        .bind(id)
        .fetch_optional(&st.db)
        .await?
        .ok_or(AppError::NotFound)?;
    if trip.rider_id != claims.sub && trip.driver_id != Some(claims.sub) && !claims.is_staff() {
        return Err(AppError::Forbidden);
    }
    Ok(Json(trip))
}

async fn list_mine(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Vec<Trip>>> {
    let trips: Vec<Trip> = sqlx::query_as(&format!(
        "SELECT {TRIP_COLS} FROM trips WHERE rider_id = $1 OR driver_id = $1 ORDER BY created_at DESC LIMIT 100"
    ))
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(trips))
}
