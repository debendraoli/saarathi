//! Contributor-facing routes: submit a place, view your own submissions,
//! points/badges, and redeem points for wallet credit.

use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::points::{self, MIN_REDEEM_POINTS, POINTS_TO_NPR_RATE};
use crate::state::AppState;
use axum::extract::{Multipart, Query, State};
use axum::{
    Json, Router,
    routing::{get, post},
};
use rust_decimal::Decimal;
use saarathi_core::routing::{LatLng, haversine_km};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

/// Beyond this, the claimed pin and where the photo was actually taken are
/// too far apart to trust — rural Dang GPS drift tolerance, not a hard
/// science; tune once there's real submission data.
const MAX_CAPTURE_DISTANCE_M: f64 = 150.0;

const ALLOWED_CATEGORIES: [&str; 7] = [
    "organisation",
    "building",
    "landmark",
    "construction",
    "closed_road",
    "sign",
    "other",
];

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/places/contributions", post(submit))
        .route("/v1/places/contributions/mine", get(mine))
        .route("/v1/places/points", get(points_summary))
        .route("/v1/places/points/redeem", post(redeem))
        .route("/v1/places/nearby", get(nearby))
}

#[derive(Serialize, sqlx::FromRow)]
struct Contribution {
    id: Uuid,
    category: String,
    name: String,
    description: Option<String>,
    lat: f64,
    lng: f64,
    status: String,
    rejection_reason: Option<String>,
    points_awarded: Option<i32>,
    created_at: chrono::DateTime<chrono::Utc>,
}

const CONTRIBUTION_COLS: &str = "id, category::text AS category, name, description, lat, lng, \
    status, rejection_reason, points_awarded, created_at";

async fn submit(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    mut multipart: Multipart,
) -> AppResult<Json<Contribution>> {
    let mut category: Option<String> = None;
    let mut name: Option<String> = None;
    let mut description: Option<String> = None;
    let mut lat: Option<f64> = None;
    let mut lng: Option<f64> = None;
    let mut capture_lat: Option<f64> = None;
    let mut capture_lng: Option<f64> = None;
    let mut content_type: Option<String> = None;
    let mut photo: Option<Vec<u8>> = None;

    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| AppError::BadRequest(e.to_string()))?
    {
        let name_of = field.name().map(str::to_string);
        match name_of.as_deref() {
            Some("category") => category = Some(text(field).await?),
            Some("name") => name = Some(text(field).await?),
            Some("description") => description = Some(text(field).await?),
            Some("lat") => lat = Some(parse_f64(&text(field).await?)?),
            Some("lng") => lng = Some(parse_f64(&text(field).await?)?),
            Some("capture_lat") => capture_lat = Some(parse_f64(&text(field).await?)?),
            Some("capture_lng") => capture_lng = Some(parse_f64(&text(field).await?)?),
            Some("photo") => {
                content_type = field.content_type().map(str::to_string);
                let data = field
                    .bytes()
                    .await
                    .map_err(|e| AppError::BadRequest(e.to_string()))?;
                photo = Some(data.to_vec());
            }
            _ => {}
        }
    }

    let category = category.ok_or_else(|| AppError::BadRequest("missing 'category'".into()))?;
    if !ALLOWED_CATEGORIES.contains(&category.as_str()) {
        return Err(AppError::BadRequest("invalid category".into()));
    }
    let name = name.ok_or_else(|| AppError::BadRequest("missing 'name'".into()))?;
    if name.trim().is_empty() {
        return Err(AppError::BadRequest("name can't be empty".into()));
    }
    let lat = lat.ok_or_else(|| AppError::BadRequest("missing 'lat'".into()))?;
    let lng = lng.ok_or_else(|| AppError::BadRequest("missing 'lng'".into()))?;
    let capture_lat =
        capture_lat.ok_or_else(|| AppError::BadRequest("missing 'capture_lat'".into()))?;
    let capture_lng =
        capture_lng.ok_or_else(|| AppError::BadRequest("missing 'capture_lng'".into()))?;
    let photo = photo.ok_or_else(|| AppError::BadRequest("missing 'photo'".into()))?;
    if photo.is_empty() {
        return Err(AppError::BadRequest("empty photo".into()));
    }

    let capture_distance_m = haversine_km(
        LatLng { lat, lng },
        LatLng {
            lat: capture_lat,
            lng: capture_lng,
        },
    ) * 1000.0;
    if capture_distance_m > MAX_CAPTURE_DISTANCE_M {
        return Err(AppError::BadRequest(format!(
            "you're {:.0}m from the pinned location — move closer and retake the photo to submit",
            capture_distance_m
        )));
    }

    let storage_key = format!("{}/{}", claims.sub, Uuid::new_v4());
    st.docs
        .put(&storage_key, photo)
        .await
        .map_err(AppError::Other)?;
    let _ = content_type; // stored bytes are self-describing enough for v1; not persisted separately

    let contribution: Contribution = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "INSERT INTO place_contributions \
            (contributor_id, category, name, description, lat, lng, photo_storage_key, \
             capture_lat, capture_lng, capture_distance_m) \
         VALUES ($1, $2::place_category, $3, $4, $5, $6, $7, $8, $9, $10) \
         RETURNING {CONTRIBUTION_COLS}"
    )))
    .bind(claims.sub)
    .bind(&category)
    .bind(&name)
    .bind(&description)
    .bind(lat)
    .bind(lng)
    .bind(&storage_key)
    .bind(capture_lat)
    .bind(capture_lng)
    .bind(capture_distance_m)
    .fetch_one(&st.db)
    .await?;

    Ok(Json(contribution))
}

async fn text(field: axum::extract::multipart::Field<'_>) -> AppResult<String> {
    field
        .text()
        .await
        .map_err(|e| AppError::BadRequest(e.to_string()))
}

fn parse_f64(s: &str) -> AppResult<f64> {
    s.parse()
        .map_err(|_| AppError::BadRequest(format!("invalid number: {s}")))
}

#[cfg(test)]
mod parse_f64_tests {
    use super::*;

    #[test]
    fn parses_plain_and_negative_and_decimal_numbers() {
        assert_eq!(parse_f64("27.7172").unwrap(), 27.7172);
        assert_eq!(parse_f64("-85.324").unwrap(), -85.324);
        assert_eq!(parse_f64("0").unwrap(), 0.0);
    }

    #[test]
    fn rejects_garbage_with_a_bad_request_not_a_panic() {
        assert!(parse_f64("not a number").is_err());
        assert!(parse_f64("").is_err());
        assert!(parse_f64("27.7,85.3").is_err()); // a lat/lng pair pasted whole, not split
    }
}

async fn mine(State(st): State<AppState>, AuthUser(claims): AuthUser) -> AppResult<Json<Value>> {
    let items: Vec<Contribution> = sqlx::query_as(sqlx::AssertSqlSafe(format!(
        "SELECT {CONTRIBUTION_COLS} FROM place_contributions \
         WHERE contributor_id = $1 ORDER BY created_at DESC LIMIT 100"
    )))
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(json!({ "items": items })))
}

#[derive(Serialize, sqlx::FromRow)]
struct Badge {
    badge_code: String,
    awarded_at: chrono::DateTime<chrono::Utc>,
}

async fn points_summary(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Value>> {
    let balance: Option<i64> = sqlx::query_scalar(
        "SELECT SUM(CASE WHEN kind = 'earned' THEN points ELSE -points END) \
         FROM points_ledger WHERE user_id = $1",
    )
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await?;
    let badges: Vec<Badge> = sqlx::query_as(
        "SELECT badge_code, awarded_at FROM contributor_badges \
         WHERE user_id = $1 ORDER BY awarded_at",
    )
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;
    let titled: Vec<Value> = badges
        .into_iter()
        .map(|b| {
            json!({
                "code": b.badge_code,
                "title": points::badge_title(&b.badge_code),
                "awarded_at": b.awarded_at,
            })
        })
        .collect();
    Ok(Json(json!({
        "balance": balance.unwrap_or(0),
        "badges": titled,
        "min_redeem_points": MIN_REDEEM_POINTS,
        "points_to_npr_rate": POINTS_TO_NPR_RATE,
    })))
}

#[derive(Deserialize)]
struct RedeemInput {
    points: i32,
}

async fn redeem(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<RedeemInput>,
) -> AppResult<Json<Value>> {
    if body.points < MIN_REDEEM_POINTS {
        return Err(AppError::BadRequest(format!(
            "redeem at least {MIN_REDEEM_POINTS} points at a time"
        )));
    }

    let mut tx = st.db.begin().await?;
    // Lock this user's ledger rows for the duration so two concurrent redeem
    // taps can't both read the same balance and double-spend it. Postgres
    // won't allow FOR UPDATE directly on an aggregate query, so lock the raw
    // rows in a subquery and sum those.
    let balance: Option<i64> = sqlx::query_scalar(
        "SELECT SUM(CASE WHEN kind = 'earned' THEN points ELSE -points END) FROM ( \
            SELECT points, kind FROM points_ledger WHERE user_id = $1 FOR UPDATE \
         ) locked",
    )
    .bind(claims.sub)
    .fetch_one(&mut *tx)
    .await?;
    let balance = balance.unwrap_or(0);
    if (body.points as i64) > balance {
        return Err(AppError::bad(
            saarathi_core::api::ErrorCode::Validation,
            "insufficient points balance",
        ));
    }

    let npr_amount = Decimal::from(body.points) / Decimal::from(POINTS_TO_NPR_RATE);
    let redemption_id: Uuid = sqlx::query_scalar(
        "INSERT INTO points_redemptions (user_id, points_spent, npr_amount) \
         VALUES ($1, $2, $3) RETURNING id",
    )
    .bind(claims.sub)
    .bind(body.points)
    .bind(npr_amount)
    .fetch_one(&mut *tx)
    .await?;
    sqlx::query("INSERT INTO points_ledger (user_id, points, kind) VALUES ($1, $2, 'redeemed')")
        .bind(claims.sub)
        .bind(body.points)
        .execute(&mut *tx)
        .await?;
    let new_balance = saarathi_core::wallet::credit_rider(
        &mut tx,
        claims.sub,
        npr_amount,
        "places_points_redemption",
        Some(&redemption_id.to_string()),
        None,
    )
    .await?;
    tx.commit().await?;

    Ok(Json(json!({
        "ok": true,
        "points_spent": body.points,
        "npr_credited": npr_amount,
        "wallet_balance": new_balance,
    })))
}

#[derive(Deserialize)]
struct NearbyQuery {
    lat: f64,
    lng: f64,
    #[serde(default = "default_radius")]
    radius_m: f64,
}

fn default_radius() -> f64 {
    2000.0
}

#[derive(Serialize, sqlx::FromRow)]
struct NearbyPlace {
    id: Uuid,
    category: String,
    name: String,
    lat: f64,
    lng: f64,
}

/// Approved + navigable places near a point — a coarse bounding-box
/// prefilter (cheap, no PostGIS dependency in this service) then an exact
/// haversine filter/sort in Rust. Fine at this scale; revisit if the places
/// table grows large enough for that filter to matter.
async fn nearby(
    State(st): State<AppState>,
    Query(q): Query<NearbyQuery>,
) -> AppResult<Json<Value>> {
    // ~1 degree latitude ≈ 111km; pad the box generously, exact filter below.
    let deg = (q.radius_m / 111_000.0).max(0.01);
    let navigable: Vec<&str> = ALLOWED_CATEGORIES
        .into_iter()
        .filter(|c| points::is_navigable(c))
        .collect();
    let rows: Vec<NearbyPlace> = sqlx::query_as(
        "SELECT id, category::text AS category, name, lat, lng FROM place_contributions \
         WHERE status = 'approved' \
           AND category::text = ANY($4) \
           AND lat BETWEEN $1 - $3 AND $1 + $3 AND lng BETWEEN $2 - $3 AND $2 + $3",
    )
    .bind(q.lat)
    .bind(q.lng)
    .bind(deg)
    .bind(&navigable)
    .fetch_all(&st.db)
    .await?;

    let origin = LatLng {
        lat: q.lat,
        lng: q.lng,
    };
    let mut items: Vec<_> = rows
        .into_iter()
        .filter(|p| {
            haversine_km(
                origin,
                LatLng {
                    lat: p.lat,
                    lng: p.lng,
                },
            ) * 1000.0
                <= q.radius_m
        })
        .collect();
    items.sort_by(|a, b| {
        let da = haversine_km(
            origin,
            LatLng {
                lat: a.lat,
                lng: a.lng,
            },
        );
        let db = haversine_km(
            origin,
            LatLng {
                lat: b.lat,
                lng: b.lng,
            },
        );
        da.total_cmp(&db)
    });
    Ok(Json(json!({ "items": items })))
}
