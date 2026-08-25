//! Fare-bidding auction: driver bids against a rider's ask, rider picks one.
//! See AGENTS.md / the bidding plan for the model — this is additive to the
//! existing instant-dispatch path (`routes::dispatch`), which is untouched.

use crate::auth::AuthUser;
use crate::dispatch;
use crate::error::{AppError, AppResult};
use crate::models::{Trip, TRIP_COLS};
use crate::notify;
use crate::pricing;
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Duration, Utc};
use rust_decimal::Decimal;
use saarathi_core::api::ErrorCode;
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/rides/{id}/bid", post(place_bid))
        .route("/v1/rides/{id}/bids", get(list_bids))
        .route("/v1/rides/{id}/bids/{bid_id}/accept", post(accept_bid))
        .route("/v1/rides/{id}/ask", post(change_ask))
}

async fn load_bid_trip(st: &AppState, id: Uuid) -> AppResult<Trip> {
    let trip: Option<Trip> = sqlx::query_as(sqlx::AssertSqlSafe(format!("SELECT {TRIP_COLS} FROM trips WHERE id = $1")))
        .bind(id)
        .fetch_optional(&st.db)
        .await?;
    let trip = trip.ok_or(AppError::NotFound)?;
    if trip.pricing_mode != "bid" {
        return Err(AppError::bad(
            ErrorCode::TripUnavailable,
            "trip is not open for bidding",
        ));
    }
    Ok(trip)
}

#[derive(Deserialize)]
struct BidRequest {
    amount: Decimal,
}

/// Driver places or revises a bid. Requires having been invited into this
/// auction (a `trip_offers` row, any status — the auction is open-ended, so
/// an invite doesn't need to still be within its narrow TTL to bid on).
/// `amount == ask` is a plain accept; `amount > ask` is a counter, capped by
/// both the legal ceiling and `bid_counter_max_ratio` × ask. Undercutting the
/// ask is rejected outright — this is blind bidding, not a race to the floor.
async fn place_bid(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
    Json(body): Json<BidRequest>,
) -> AppResult<Json<serde_json::Value>> {
    let invited: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM trip_offers WHERE trip_id = $1 AND driver_id = $2)",
    )
    .bind(id)
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await?;
    if !invited {
        return Err(AppError::Forbidden);
    }

    // Same credit-floor gate accepting an instant offer applies — a driver
    // with no credit shouldn't be able to win a cash trip they can't settle.
    let credit_balance = crate::payments::driver_credit_balance(&st.db, claims.sub).await?;
    if credit_balance <= Decimal::ZERO {
        return Err(AppError::bad(
            ErrorCode::InsufficientDriverCredits,
            "top up your credit balance to bid on rides",
        ));
    }

    let trip = load_bid_trip(&st, id).await?;
    if trip.status != "requested" {
        return Err(AppError::bad(
            ErrorCode::TripUnavailable,
            "trip is no longer open for bidding",
        ));
    }
    let ask = trip.ask_fare.ok_or_else(|| {
        AppError::Other(anyhow::anyhow!("bid-mode trip {id} has no ask_fare"))
    })?;

    let vclass = pricing::parse_vehicle_class(&trip.vehicle_class)?;
    let ceiling = saarathi_core::pricing::legal_ceiling(vclass, trip.distance_km);
    let max_counter = (ask * st.config.bid_counter_max_ratio).min(ceiling);

    let kind = if body.amount == ask {
        "accept_ask"
    } else if body.amount > ask {
        if body.amount > max_counter {
            return Err(AppError::bad(
                ErrorCode::AmountInvalid,
                format!("counter may not exceed NPR {max_counter}"),
            ));
        }
        "counter"
    } else {
        return Err(AppError::bad(
            ErrorCode::AmountInvalid,
            "a bid may not undercut the rider's asking price",
        ));
    };

    let expires_at = Utc::now() + Duration::seconds(st.config.bid_ttl_secs);
    sqlx::query(
        "INSERT INTO trip_bids (trip_id, driver_id, amount, kind, expires_at) \
         VALUES ($1, $2, $3, $4, $5) \
         ON CONFLICT (trip_id, driver_id) WHERE status = 'live' \
         DO UPDATE SET amount = EXCLUDED.amount, kind = EXCLUDED.kind, \
             expires_at = EXCLUDED.expires_at, created_at = now()",
    )
    .bind(id)
    .bind(claims.sub)
    .bind(body.amount)
    .bind(kind)
    .bind(expires_at)
    .execute(&st.db)
    .await?;

    st.hub.publish(
        id,
        json!({ "type": "bid", "trip_id": id, "amount": body.amount, "kind": kind }).to_string(),
    );
    notify::send(
        &st.nats,
        trip.rider_id,
        saarathi_core::domain::notif::TRANSACTIONAL,
        "New bid",
        &format!("A driver bid NPR {}", body.amount),
        Some(format!("saarathi://trip/{id}")),
    )
    .await;
    Ok(Json(json!({ "ok": true, "kind": kind })))
}

#[derive(Serialize, sqlx::FromRow)]
struct BidView {
    id: Uuid,
    driver_id: Uuid,
    amount: Decimal,
    kind: String,
    expires_at: DateTime<Utc>,
    name: Option<String>,
    rating: Option<f64>,
    rating_count: i64,
    vehicle_class: Option<String>,
    make: Option<String>,
    model: Option<String>,
    plate_number: Option<String>,
    partner_name: Option<String>,
    photo_url: Option<String>,
}

/// Rider (or staff) sees every live bid, enriched with driver identity —
/// name, rating, vehicle, fleet-partner, photo (the same fields
/// `GET /v1/rides/{id}/participants` exposes once a driver's assigned).
/// Deliberately **not** driver-accessible: blind bidding means a driver only
/// ever sees the trip and the rider's ask, never rival bids — enforced here,
/// not just hidden in the UI.
async fn list_bids(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Vec<BidView>>> {
    let trip = load_bid_trip(&st, id).await?;
    if trip.rider_id != claims.sub && !claims.is_staff() {
        return Err(AppError::Forbidden);
    }

    let bids: Vec<BidView> = sqlx::query_as(
        "SELECT tb.id, tb.driver_id, tb.amount, tb.kind, tb.expires_at, \
                u.full_name AS name, \
                r.rating, r.rating_count, \
                v.class::text AS vehicle_class, v.make, v.model, v.plate_number, \
                p.name AS partner_name, \
                CASE WHEN dd.id IS NOT NULL THEN '/v1/driver/' || tb.driver_id || '/photo' END AS photo_url \
         FROM trip_bids tb \
         JOIN users u ON u.id = tb.driver_id \
         LEFT JOIN drivers d ON d.user_id = tb.driver_id \
         LEFT JOIN vehicles v ON v.driver_id = d.id \
         LEFT JOIN partner_drivers pd ON pd.driver_user_id = tb.driver_id AND pd.status = 'active' \
         LEFT JOIN partners p ON p.id = pd.partner_id AND p.status = 'active' \
         LEFT JOIN LATERAL ( \
             SELECT id FROM driver_documents \
             WHERE driver_id = d.id AND kind = 'profile_photo' \
             ORDER BY created_at DESC LIMIT 1 \
         ) dd ON true, \
         LATERAL ( \
             SELECT AVG(stars)::float8 AS rating, count(*) AS rating_count FROM ratings \
             WHERE ratee_id = tb.driver_id AND role = 'rider_rates_driver' \
         ) r \
         WHERE tb.trip_id = $1 AND tb.status = 'live' AND tb.expires_at > now() \
         ORDER BY tb.amount ASC, tb.created_at ASC",
    )
    .bind(id)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(bids))
}

/// Rider accepts a bid — binding: this assigns the trip immediately, no
/// driver re-confirmation. Backing out afterwards counts against the same
/// `MAX_DRIVER_CANCELS_PER_WINDOW` quota an abandoned instant-mode trip does.
async fn accept_bid(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path((id, bid_id)): Path<(Uuid, Uuid)>,
) -> AppResult<Json<Trip>> {
    let trip = load_bid_trip(&st, id).await?;
    if trip.rider_id != claims.sub {
        return Err(AppError::Forbidden);
    }

    let mut tx = st.db.begin().await?;

    let bid: Option<(Uuid, Decimal)> = sqlx::query_as(
        "SELECT driver_id, amount FROM trip_bids \
         WHERE id = $1 AND trip_id = $2 AND status = 'live' AND expires_at > now() FOR UPDATE",
    )
    .bind(bid_id)
    .bind(id)
    .fetch_optional(&mut *tx)
    .await?;
    let Some((driver_id, amount)) = bid else {
        return Err(AppError::conflict(
            ErrorCode::OfferExpired,
            "bid expired or not found",
        ));
    };

    // One active trip per driver at a time (same invariant accept_offer enforces).
    let already_active: Option<Uuid> = sqlx::query_scalar(
        "SELECT id FROM trips WHERE driver_id = $1 \
         AND status IN ('accepted', 'arriving', 'in_progress') LIMIT 1",
    )
    .bind(driver_id)
    .fetch_optional(&mut *tx)
    .await?;
    if already_active.is_some() {
        return Err(AppError::conflict(
            ErrorCode::TripUnavailable,
            "that driver just became unavailable — pick another bid",
        ));
    }

    let (commission, accident_fund, driver_payout, final_fare) =
        pricing::split_agreed_fare(amount, trip.discount_amount, st.config.commission_rate);

    // `driver_id IS NULL` is the lock: two concurrent accepts on this trip
    // (different bids, or a race with instant-mode assignment) can't both win.
    let updated: Option<Trip> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "UPDATE trips SET driver_id = $2, status = 'accepted', accepted_at = now(), \
            updated_at = now(), gross_fare = $3, commission = $4, accident_fund = $5, \
            driver_payout = $6, final_fare = $7 \
         WHERE id = $1 AND driver_id IS NULL RETURNING {TRIP_COLS}"
    )))
    .bind(id)
    .bind(driver_id)
    .bind(amount)
    .bind(commission)
    .bind(accident_fund)
    .bind(driver_payout)
    .bind(final_fare)
    .fetch_optional(&mut *tx)
    .await
    .map_err(|e| match e {
        // trips_driver_one_active_idx backstop: lost the race against another
        // accept for this driver that committed first.
        sqlx::Error::Database(db) if db.is_unique_violation() => AppError::conflict(
            ErrorCode::TripUnavailable,
            "that driver just became unavailable — pick another bid",
        ),
        other => AppError::Db(other),
    })?;
    let Some(updated) = updated else {
        return Err(AppError::conflict(
            ErrorCode::TripUnavailable,
            "trip is no longer available",
        ));
    };

    sqlx::query("UPDATE trip_bids SET status = 'won' WHERE id = $1")
        .bind(bid_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        "UPDATE trip_bids SET status = 'lost' WHERE trip_id = $1 AND status = 'live' AND id <> $2",
    )
    .bind(id)
    .bind(bid_id)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "UPDATE trip_offers SET status = 'expired' WHERE trip_id = $1 AND status = 'offered'",
    )
    .bind(id)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO fare_negotiations (trip_id, algo_fare, floor, ceiling, offered_fare, agreed_fare) \
         VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(id)
    .bind(trip.gross_fare)
    .bind(trip.ask_fare.unwrap_or(trip.gross_fare))
    .bind(saarathi_core::pricing::legal_ceiling(
        pricing::parse_vehicle_class(&trip.vehicle_class)?,
        trip.distance_km,
    ))
    .bind(amount)
    .bind(amount)
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;

    st.hub.publish(
        id,
        json!({ "type": "status", "status": "accepted", "driver_id": driver_id }).to_string(),
    );
    crate::notify::send(
        &st.nats,
        driver_id,
        saarathi_core::domain::notif::TRANSACTIONAL,
        "Bid accepted",
        "Your bid was accepted — head to the pickup point.",
        Some(format!("saarathi://trip/{id}")),
    )
    .await;
    Ok(Json(updated))
}

#[derive(Deserialize)]
struct AskRequest {
    amount: Decimal,
}

/// Rider raises (or lowers) the asking price mid-auction. Existing bids
/// stand untouched — a driver who countered at 110 isn't affected by the
/// ask moving 84 → 95 — this just re-broadcasts to reach drivers who were
/// passed over at the old, lower ask.
async fn change_ask(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
    Json(body): Json<AskRequest>,
) -> AppResult<Json<Trip>> {
    let trip = load_bid_trip(&st, id).await?;
    if trip.rider_id != claims.sub {
        return Err(AppError::Forbidden);
    }
    if trip.status != "requested" {
        return Err(AppError::bad(
            ErrorCode::TripUnavailable,
            "trip is no longer accepting a new ask",
        ));
    }

    let vclass = pricing::parse_vehicle_class(&trip.vehicle_class)?;
    let ceiling = saarathi_core::pricing::legal_ceiling(vclass, trip.distance_km);
    let floor = (trip.gross_fare * st.config.bargain_floor_ratio).round_dp(2);
    let ask = body.amount.max(floor).min(ceiling);

    let updated: Trip = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "UPDATE trips SET ask_fare = $2, updated_at = now() WHERE id = $1 RETURNING {TRIP_COLS}"
    )))
    .bind(id)
    .bind(ask)
    .fetch_one(&st.db)
    .await?;

    st.hub.publish(
        id,
        json!({ "type": "ask", "trip_id": id, "amount": ask }).to_string(),
    );
    if let Err(e) = dispatch::dispatch_trip(&st, id).await {
        tracing::warn!(trip = %id, error = %e, "redispatch after change_ask failed");
    }
    Ok(Json(updated))
}
