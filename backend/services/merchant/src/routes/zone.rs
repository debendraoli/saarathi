//! Merchant delivery/visibility geofences: a polygon boundary, cached as its
//! H3 resolution-9 cell coverage in Redis (`saarathi_core::geo_h3::polyfill`)
//! so a later "is this point inside the merchant's zone" check (Phase 4's
//! geofence-bounded order visibility) is a single `SISMEMBER`, not a PostGIS
//! point-in-polygon query per lookup.
//!
//! Invalidation strategy: there is no separate cache-bust step — the cache is
//! recomputed synchronously in the same request that writes `zone_polygon`,
//! so it can never observe a polygon edit without being regenerated. A 24h
//! TTL is a self-healing backstop, not the primary invalidation mechanism.

use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::routes::marketplace::owns_or_staff;
use crate::state::AppState;
use axum::extract::{Path, Query, State};
use axum::{routing::get, Json, Router};
use saarathi_core::geo_h3;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

/// Backstop only (see module docs) — the cache is always rewritten on edit.
const ZONE_CACHE_TTL_SECS: i64 = 86_400;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/merchant/zone/{id}", get(get_zone).put(set_zone))
        .route("/v1/merchant/zone/{id}/contains", get(contains))
}

fn zone_key(merchant_id: Uuid) -> String {
    format!("merchant:zone:h3:{merchant_id}")
}

#[derive(Deserialize, Serialize)]
struct Point {
    lat: f64,
    lng: f64,
}

#[derive(Deserialize)]
struct SetZone {
    points: Vec<Point>,
}

async fn set_zone(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(merchant_id): Path<Uuid>,
    Json(body): Json<SetZone>,
) -> AppResult<Json<Value>> {
    if !owns_or_staff(&st, claims.sub, claims.is_staff(), merchant_id).await? {
        return Err(AppError::Forbidden);
    }
    if body.points.len() < 3 {
        return Err(AppError::BadRequest(
            "a zone polygon needs at least 3 points".into(),
        ));
    }
    let pairs: Vec<(f64, f64)> = body.points.iter().map(|p| (p.lat, p.lng)).collect();
    let cells = geo_h3::polyfill(&pairs).map_err(AppError::Other)?;

    let polygon_json = serde_json::to_value(&body.points).expect("points serialize");
    sqlx::query("UPDATE merchants SET zone_polygon = $2 WHERE id = $1")
        .bind(merchant_id)
        .bind(&polygon_json)
        .execute(&st.db)
        .await?;

    let mut r = st.redis.clone();
    let key = zone_key(merchant_id);
    let _: () = redis::cmd("DEL")
        .arg(&key)
        .query_async(&mut r)
        .await
        .map_err(anyhow::Error::from)
        .map_err(AppError::Other)?;
    if !cells.is_empty() {
        let members: Vec<String> = cells.iter().map(|c| u64::from(*c).to_string()).collect();
        let mut cmd = redis::cmd("SADD");
        cmd.arg(&key);
        for m in &members {
            cmd.arg(m);
        }
        let _: () = cmd
            .query_async(&mut r)
            .await
            .map_err(anyhow::Error::from)
            .map_err(AppError::Other)?;
        let _: () = redis::cmd("EXPIRE")
            .arg(&key)
            .arg(ZONE_CACHE_TTL_SECS)
            .query_async(&mut r)
            .await
            .map_err(anyhow::Error::from)
            .map_err(AppError::Other)?;
    }

    Ok(Json(json!({ "ok": true, "cell_count": cells.len() })))
}

#[derive(Serialize)]
struct ZoneResponse {
    merchant_id: Uuid,
    points: Vec<Point>,
    cell_count: usize,
}

async fn get_zone(
    State(st): State<AppState>,
    Path(merchant_id): Path<Uuid>,
) -> AppResult<Json<ZoneResponse>> {
    let row: Option<(Option<serde_json::Value>,)> =
        sqlx::query_as("SELECT zone_polygon FROM merchants WHERE id = $1")
            .bind(merchant_id)
            .fetch_optional(&st.db)
            .await?;
    let Some((polygon,)) = row else {
        return Err(AppError::NotFound);
    };
    let points: Vec<Point> = polygon
        .map(|v| serde_json::from_value(v).unwrap_or_default())
        .unwrap_or_default();

    let mut r = st.redis.clone();
    let cell_count: usize = redis::cmd("SCARD")
        .arg(zone_key(merchant_id))
        .query_async(&mut r)
        .await
        .unwrap_or(0);

    Ok(Json(ZoneResponse {
        merchant_id,
        points,
        cell_count,
    }))
}

/// Whether `(lat, lng)` falls inside `merchant_id`'s cached delivery zone.
/// `None` means the merchant has no zone defined — callers should treat that
/// as "unbounded" or "unset", not "outside", since it's a different state.
pub async fn is_point_in_zone(
    st: &AppState,
    merchant_id: Uuid,
    lat: f64,
    lng: f64,
) -> anyhow::Result<Option<bool>> {
    let mut r = st.redis.clone();
    let key = zone_key(merchant_id);
    let exists: bool = redis::cmd("EXISTS").arg(&key).query_async(&mut r).await?;
    if !exists {
        return Ok(None);
    }
    let cell = geo_h3::cell_for(lat, lng)?;
    let is_member: bool = redis::cmd("SISMEMBER")
        .arg(&key)
        .arg(u64::from(cell).to_string())
        .query_async(&mut r)
        .await?;
    Ok(Some(is_member))
}

#[derive(Deserialize)]
struct ContainsQuery {
    lat: f64,
    lng: f64,
}

/// "Does this merchant deliver to this point?" — public (no auth), the same
/// question a checkout screen would ask before letting someone order.
async fn contains(
    State(st): State<AppState>,
    Path(merchant_id): Path<Uuid>,
    Query(q): Query<ContainsQuery>,
) -> AppResult<Json<Value>> {
    match is_point_in_zone(&st, merchant_id, q.lat, q.lng)
        .await
        .map_err(AppError::Other)?
    {
        Some(inside) => Ok(Json(json!({ "zone_defined": true, "contains": inside }))),
        None => Ok(Json(json!({ "zone_defined": false, "contains": null }))),
    }
}
