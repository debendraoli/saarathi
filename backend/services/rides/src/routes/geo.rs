//! Geocoding proxy for address autocomplete + reverse lookup. Wraps a Photon
//! instance (self-hosted in prod, public komoot for dev — GEOCODER_URL). Results
//! degrade gracefully to an empty list so the search box never errors out.
//!
//! Reverse lookups are cached in Redis by H3 resolution-9 cell (~174m² hex —
//! reuses the platform's existing spatial index rather than inventing a
//! rounding scheme) so GPS breadcrumb trails, which revisit the same
//! neighborhood repeatedly, don't hit the upstream geocoder per point.
//! Misses are cached too (as an empty marker) so a point with no address
//! doesn't get re-queried on every repeat visit either.

use crate::auth::AuthUser;
use crate::error::AppResult;
use crate::state::AppState;
use axum::extract::{Query, State};
use axum::{routing::get, Json, Router};
use saarathi_core::geo_h3::cell_for;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::OnceLock;
use std::time::Duration;

/// Addresses don't move; 30 days is a self-healing backstop, not the primary
/// invalidation mechanism (there isn't one — reverse-geocode results are
/// treated as effectively immutable).
const REVERSE_CACHE_TTL_SECS: i64 = 30 * 24 * 3600;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/geo/search", get(search))
        .route("/v1/geo/reverse", get(reverse))
}

fn http() -> &'static reqwest::Client {
    static C: OnceLock<reqwest::Client> = OnceLock::new();
    C.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .expect("http client")
    })
}

fn geocoder_url() -> String {
    std::env::var("GEOCODER_URL")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "https://photon.komoot.io".into())
        .trim_end_matches('/')
        .to_string()
}

#[derive(Serialize, Deserialize, Clone)]
struct GeoPlace {
    label: String,
    address: String,
    lat: f64,
    lng: f64,
}

#[derive(Deserialize)]
struct SearchQuery {
    q: String,
    lat: Option<f64>,
    lng: Option<f64>,
}

async fn search(_auth: AuthUser, Query(q): Query<SearchQuery>) -> AppResult<Json<Vec<GeoPlace>>> {
    let query = q.q.trim();
    if query.chars().count() < 2 {
        return Ok(Json(vec![]));
    }
    let mut params: Vec<(&str, String)> = vec![
        ("q", query.to_string()),
        ("limit", "8".into()),
        ("lang", "en".into()),
        // Restrict to Nepal's bounding box (minLon,minLat,maxLon,maxLat).
        ("bbox", "80.0,26.3,88.2,30.5".into()),
    ];
    // Bias toward the user's location when known.
    if let (Some(lat), Some(lng)) = (q.lat, q.lng) {
        params.push(("lat", lat.to_string()));
        params.push(("lon", lng.to_string()));
    }
    let places = fetch(&format!("{}/api", geocoder_url()), &params)
        .await
        .unwrap_or_default();
    Ok(Json(places))
}

#[derive(Deserialize)]
struct ReverseQuery {
    lat: f64,
    lng: f64,
}

fn reverse_cache_key(lat: f64, lng: f64) -> Option<String> {
    let cell = cell_for(lat, lng).ok()?;
    Some(format!("geo:reverse:{}", u64::from(cell)))
}

async fn reverse(
    State(st): State<AppState>,
    _auth: AuthUser,
    Query(q): Query<ReverseQuery>,
) -> AppResult<Json<Option<GeoPlace>>> {
    let key = reverse_cache_key(q.lat, q.lng);
    if let Some(key) = &key {
        let mut r = st.redis.clone();
        if let Ok(cached) = redis::cmd("GET")
            .arg(key)
            .query_async::<Option<String>>(&mut r)
            .await
        {
            if let Some(raw) = cached {
                let place: Option<GeoPlace> = serde_json::from_str(&raw).unwrap_or(None);
                return Ok(Json(place));
            }
        }
    }

    let params: Vec<(&str, String)> = vec![("lat", q.lat.to_string()), ("lon", q.lng.to_string())];
    let place = fetch(&format!("{}/reverse", geocoder_url()), &params)
        .await
        .unwrap_or_default()
        .into_iter()
        .next();

    if let Some(key) = &key {
        let mut r = st.redis.clone();
        if let Ok(raw) = serde_json::to_string(&place) {
            let _: Result<(), _> = redis::cmd("SET")
                .arg(key)
                .arg(raw)
                .arg("EX")
                .arg(REVERSE_CACHE_TTL_SECS)
                .query_async::<()>(&mut r)
                .await;
        }
    }
    Ok(Json(place))
}

/// Query Photon and map its GeoJSON features to our flat place shape.
async fn fetch(url: &str, params: &[(&str, String)]) -> Result<Vec<GeoPlace>, ()> {
    let resp = http().get(url).query(params).send().await.map_err(|_| ())?;
    let body: Value = resp.json().await.map_err(|_| ())?;
    let features = body
        .get("features")
        .and_then(|f| f.as_array())
        .cloned()
        .unwrap_or_default();
    Ok(features.iter().filter_map(feature_to_place).collect())
}

fn feature_to_place(f: &Value) -> Option<GeoPlace> {
    let coords = f.pointer("/geometry/coordinates")?.as_array()?;
    let lng = coords.first()?.as_f64()?;
    let lat = coords.get(1)?.as_f64()?;
    let p = f.get("properties")?;
    let get = |k: &str| p.get(k).and_then(|v| v.as_str()).map(str::to_string);

    // Nepal only: drop anything the geocoder tags as another country.
    if let Some(cc) = get("countrycode") {
        if !cc.eq_ignore_ascii_case("NP") {
            return None;
        }
    }

    let name = get("name");
    let street = get("street");
    let housenumber = get("housenumber");
    let city = get("city").or_else(|| get("district"));
    let state = get("state");
    let country = get("country");

    // Prefer the POI/street name; fall back to the street + number.
    let street_line = match (&street, &housenumber) {
        (Some(s), Some(n)) => Some(format!("{s} {n}")),
        (Some(s), None) => Some(s.clone()),
        _ => None,
    };
    let label = name.clone().or_else(|| street_line.clone())?;

    // Address = everything except the label, de-duplicated in order.
    let mut parts: Vec<String> = Vec::new();
    for part in [street_line.clone(), city, state, country]
        .into_iter()
        .flatten()
    {
        if part != label && !parts.contains(&part) {
            parts.push(part);
        }
    }
    Some(GeoPlace {
        label,
        address: parts.join(", "),
        lat,
        lng,
    })
}
