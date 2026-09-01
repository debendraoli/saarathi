//! Cross-merchant item search, and serving an individual item's photo.

use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::body::Bytes;
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::IntoResponse;
use axum::Json;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

// ── Cross-merchant item search ───────────────────────────────────────────────

#[derive(Deserialize)]
pub(super) struct ItemSearchQuery {
    q: String,
    lat: Option<f64>,
    lng: Option<f64>,
    vertical: Option<String>,
    /// nearest (default) | cheapest | rating
    sort: Option<String>,
}

#[derive(Serialize, sqlx::FromRow)]
pub(super) struct ItemHit {
    id: Uuid,
    merchant_id: Uuid,
    merchant_name: String,
    vertical: String,
    name: String,
    description: Option<String>,
    category: Option<String>,
    price: Decimal,
    image_key: Option<String>,
    rating: Decimal,
    distance_m: f64,
}

/// Search available items across all open merchants, sorted by nearest /
/// cheapest / top-rated.
pub(super) async fn search_items(
    State(st): State<AppState>,
    _auth: AuthUser,
    Query(q): Query<ItemSearchQuery>,
) -> AppResult<Json<Vec<ItemHit>>> {
    let term = q.q.trim();
    if term.chars().count() < 2 {
        return Ok(Json(vec![]));
    }
    let lat = q.lat.unwrap_or(28.033);
    let lng = q.lng.unwrap_or(82.484);
    // Whitelisted sort — never interpolate user input into SQL.
    let order = match q.sort.as_deref() {
        Some("cheapest") => "mi.price ASC, distance_m ASC",
        Some("rating") => "m.rating DESC, distance_m ASC",
        _ => "distance_m ASC",
    };
    let sql = format!(
        "SELECT mi.id, mi.merchant_id, m.name AS merchant_name, m.vertical, mi.name, \
                mi.description, mi.category, mi.price, mi.image_key, m.rating, \
                ST_Distance(m.geog, ST_SetSRID(ST_MakePoint($2, $1), 4326)::geography) AS distance_m \
         FROM menu_items mi JOIN merchants m ON m.id = mi.merchant_id \
         WHERE mi.is_available AND m.is_open AND m.status = 'approved' AND mi.name ILIKE $3 \
               AND ($4::text IS NULL OR m.vertical = $4) \
         ORDER BY {order} LIMIT 40"
    );
    let rows: Vec<ItemHit> = sqlx::query_as(sqlx::AssertSqlSafe(sql))
        .bind(lat)
        .bind(lng)
        .bind(format!("%{term}%"))
        .bind(q.vertical)
        .fetch_all(&st.db)
        .await?;
    Ok(Json(rows))
}

pub(super) async fn item_photo(
    State(st): State<AppState>,
    Path(id): Path<Uuid>,
) -> AppResult<impl IntoResponse> {
    let key: Option<String> =
        sqlx::query_scalar("SELECT photo_storage_key FROM menu_items WHERE id = $1")
            .bind(id)
            .fetch_optional(&st.db)
            .await?
            .flatten();
    let key = key.ok_or(AppError::NotFound)?;
    let bytes = st.docs.get(&key).await.map_err(AppError::Other)?;
    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        "application/octet-stream".parse().unwrap(),
    );
    Ok((StatusCode::OK, headers, Bytes::from(bytes)))
}
