//! Fare-bidding auction: driver bids against a rider's ask, rider picks one.
//! See AGENTS.md / the bidding plan for the model — this is additive to the
//! existing instant-dispatch path (`routes::dispatch`), which is untouched.

use crate::auth::AuthUser;
use crate::dispatch;
use crate::error::{AppError, AppResult};
use crate::models::{TRIP_COLS, Trip};
use crate::notify;
use crate::pricing;
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{
    Json, Router,
    routing::{get, post},
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
    let trip: Option<Trip> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {TRIP_COLS} FROM trips WHERE id = $1"
    )))
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
pub(crate) struct BidRequest {
    pub(crate) amount: Decimal,
}

/// Everything `place_bid` actually does, factored out so the trip's
/// WebSocket (`ws.rs`) can accept a `bid` frame sent from the moment
/// bidding opens — before a driver is anywhere near being assigned to this
/// trip, the trip row (and its socket) already exists — rather than only
/// ever being reachable over HTTP.
pub(crate) async fn do_place_bid(
    st: &AppState,
    claims: &crate::auth::Claims,
    id: Uuid,
    body: BidRequest,
) -> AppResult<serde_json::Value> {
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

    let trip = load_bid_trip(st, id).await?;
    if trip.status != "requested" {
        return Err(AppError::bad(
            ErrorCode::TripUnavailable,
            "trip is no longer open for bidding",
        ));
    }
    let ask = trip
        .ask_fare
        .ok_or_else(|| AppError::Other(anyhow::anyhow!("bid-mode trip {id} has no ask_fare")))?;

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
    let bid_id: Uuid = sqlx::query_scalar(
        "INSERT INTO trip_bids (trip_id, driver_id, amount, kind, expires_at) \
         VALUES ($1, $2, $3, $4, $5) \
         ON CONFLICT (trip_id, driver_id) WHERE status = 'live' \
         DO UPDATE SET amount = EXCLUDED.amount, kind = EXCLUDED.kind, \
             expires_at = EXCLUDED.expires_at, created_at = now() \
         RETURNING id",
    )
    .bind(id)
    .bind(claims.sub)
    .bind(body.amount)
    .bind(kind)
    .bind(expires_at)
    .fetch_one(&st.db)
    .await?;

    st.hub.publish(
        "trip",
        id,
        json!({ "type": "bid", "trip_id": id, "amount": body.amount, "kind": kind }).to_string(),
    );

    // A driver bidding exactly the rider's own ask is already agreement from
    // both sides (the rider set that price; the driver just accepted it) —
    // finalizing immediately instead of also waiting on a second, redundant
    // "accept" tap from the rider on a bid that already matches what they
    // asked for. A `counter` still needs the rider to actually choose it.
    // Losing the race (trip taken by another accept in the meantime) just
    // leaves this as a plain live bid for the rider to see — not an error
    // the driver placing the bid should hit, so a failed finalize here
    // falls through rather than propagating.
    if kind == "accept_ask"
        && finalize_bid(st, &trip, bid_id, claims.sub, body.amount)
            .await
            .is_ok()
    {
        return Ok(json!({ "ok": true, "kind": kind, "accepted": true }));
    }

    notify::send(
        &st.nats,
        trip.rider_id,
        saarathi_core::domain::notif::TRANSACTIONAL,
        "New bid",
        &format!("A driver bid NPR {}", body.amount),
        Some(format!("saarathi://trip/{id}")),
    )
    .await;
    Ok(json!({ "ok": true, "kind": kind, "accepted": false }))
}

async fn place_bid(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
    Json(body): Json<BidRequest>,
) -> AppResult<Json<serde_json::Value>> {
    Ok(Json(do_place_bid(&st, &claims, id, body).await?))
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
/// Everything `accept_bid` actually does, factored out for the trip
/// WebSocket the same way `do_place_bid` is.
pub(crate) async fn do_accept_bid(
    st: &AppState,
    claims: &crate::auth::Claims,
    id: Uuid,
    bid_id: Uuid,
) -> AppResult<Trip> {
    let trip = load_bid_trip(st, id).await?;
    if trip.rider_id != claims.sub {
        return Err(AppError::Forbidden);
    }

    let bid: Option<(Uuid, Decimal)> = sqlx::query_as(
        "SELECT driver_id, amount FROM trip_bids \
         WHERE id = $1 AND trip_id = $2 AND status = 'live' AND expires_at > now()",
    )
    .bind(bid_id)
    .bind(id)
    .fetch_optional(&st.db)
    .await?;
    let Some((driver_id, amount)) = bid else {
        return Err(AppError::conflict(
            ErrorCode::OfferExpired,
            "bid expired or not found",
        ));
    };

    finalize_bid(st, &trip, bid_id, driver_id, amount).await
}

async fn accept_bid(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path((id, bid_id)): Path<(Uuid, Uuid)>,
) -> AppResult<Json<Trip>> {
    Ok(Json(do_accept_bid(&st, &claims, id, bid_id).await?))
}

/// Locks in a winning bid — shared by both directions of "either party
/// accepts": the rider explicitly picking a bid ([accept_bid]), and a
/// driver's own bid already matching the rider's ask, which is just as much
/// agreement from both sides and shouldn't need a second, redundant "accept"
/// tap from the rider (see [place_bid]'s `accept_ask` case).
async fn finalize_bid(
    st: &AppState,
    trip: &Trip,
    bid_id: Uuid,
    driver_id: Uuid,
    amount: Decimal,
) -> AppResult<Trip> {
    let mut tx = st.db.begin().await?;

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
    .bind(trip.id)
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
    .bind(trip.id)
    .bind(bid_id)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "UPDATE trip_offers SET status = 'expired' WHERE trip_id = $1 AND status = 'offered'",
    )
    .bind(trip.id)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO fare_negotiations (trip_id, algo_fare, floor, ceiling, offered_fare, agreed_fare) \
         VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(trip.id)
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
        "trip",
        trip.id,
        json!({ "type": "status", "status": "accepted", "driver_id": driver_id }).to_string(),
    );
    crate::notify::send(
        &st.nats,
        driver_id,
        saarathi_core::domain::notif::TRANSACTIONAL,
        "Bid accepted",
        "Your bid was accepted — head to the pickup point.",
        Some(format!("saarathi://trip/{}", trip.id)),
    )
    .await;
    Ok(updated)
}

#[derive(Deserialize)]
pub(crate) struct AskRequest {
    pub(crate) amount: Decimal,
}

/// Everything `change_ask` actually does, factored out for the trip
/// WebSocket the same way `do_place_bid` is.
pub(crate) async fn do_change_ask(
    st: &AppState,
    claims: &crate::auth::Claims,
    id: Uuid,
    body: AskRequest,
) -> AppResult<Trip> {
    let trip = load_bid_trip(st, id).await?;
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

    let mut updated: Trip = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "UPDATE trips SET ask_fare = $2, updated_at = now() WHERE id = $1 RETURNING {TRIP_COLS}"
    )))
    .bind(id)
    .bind(ask)
    .fetch_one(&st.db)
    .await?;
    updated.ask_ceiling = Some(ceiling);

    st.hub.publish(
        "trip",
        id,
        json!({ "type": "ask", "trip_id": id, "amount": ask }).to_string(),
    );
    // The rider raised (or lowered) the ask — that's new terms, so a driver
    // who declined at the old price is fair game to be re-offered here,
    // unlike a plain redispatch.
    if let Err(e) = dispatch::dispatch_trip(st, id, true).await {
        tracing::warn!(trip = %id, error = %e, "redispatch after change_ask failed");
    }
    Ok(updated)
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
    Ok(Json(do_change_ask(&st, &claims, id, body).await?))
}
