//! Geocoding proxy for address autocomplete + reverse lookup. Wraps a Photon
//! instance (self-hosted in prod, public komoot for dev — GEOCODER_URL). Results
//! degrade gracefully to an empty list so the search box never errors out.

use crate::auth::AuthUser;
use crate::error::AppResult;
use crate::state::AppState;
use axum::extract::Query;
use axum::{routing::get, Json, Router};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::OnceLock;
use std::time::Duration;

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

#[derive(Serialize)]
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

async fn search(
    _auth: AuthUser,
    Query(q): Query<SearchQuery>,
) -> AppResult<Json<Vec<GeoPlace>>> {
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

async fn reverse(
    _auth: AuthUser,
    Query(q): Query<ReverseQuery>,
) -> AppResult<Json<Option<GeoPlace>>> {
    let params: Vec<(&str, String)> =
        vec![("lat", q.lat.to_string()), ("lon", q.lng.to_string())];
    let place = fetch(&format!("{}/reverse", geocoder_url()), &params)
        .await
        .unwrap_or_default()
        .into_iter()
        .next();
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
    for part in [street_line.clone(), city, state, country].into_iter().flatten() {
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
