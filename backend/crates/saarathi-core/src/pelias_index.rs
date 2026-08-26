//! Writes approved, navigable place-contributions straight into Pelias's
//! Elasticsearch index — the deployment's `pelias-schema` job creates the
//! stock, unmodified Pelias index/mapping, so a hand-written document in
//! its own base doc shape is indexed and searchable exactly like an
//! OSM-imported one, entirely separate from (and much simpler than) the
//! batch OSM/WhosOnFirst import jobs. Fire-and-forget, same "best effort
//! after commit" convention as `notify::send`/badge awards — a Pelias
//! write hiccup must never fail the staff approval action.

use serde_json::{json, Value};
use std::sync::OnceLock;
use std::time::Duration;
use uuid::Uuid;

fn http() -> &'static reqwest::Client {
    static C: OnceLock<reqwest::Client> = OnceLock::new();
    C.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(Duration::from_secs(5))
            .build()
            .expect("http client")
    })
}

/// Pelias's own `/v1/autocomplete` silently drops a document that has no
/// admin hierarchy beyond `parent.country_a` — confirmed empirically: a doc
/// with only `country_a` set never appears in results (at any `size`, even
/// though it's a perfect text match and is directly fetchable by `_id`),
/// while the identical doc with `region`/`county` populated too shows up
/// immediately. So a bare `country_a`-only `parent` (what every OSM-imported
/// doc in this index never has) isn't enough — we borrow the real admin
/// hierarchy from whichever indexed place is nearest to this contribution's
/// coordinates, via a plain geo-distance ES query against the same index
/// we're about to write into (no dependency on the separate `pelias-api`
/// service, which this deployment's `places` service has no URL for).
async fn nearest_parent(es_url: &str, lat: f64, lng: f64) -> Option<Value> {
    let url = format!("{}/pelias/_search", es_url.trim_end_matches('/'));
    let body = json!({
        "size": 1,
        "_source": ["parent"],
        "query": {
            "bool": {
                "filter": [
                    { "exists": { "field": "parent.region" } },
                    {
                        "geo_distance": {
                            "distance": "100km",
                            "center_point": { "lat": lat, "lon": lng }
                        }
                    }
                ]
            }
        },
        "sort": [
            {
                "_geo_distance": {
                    "center_point": { "lat": lat, "lon": lng },
                    "order": "asc",
                    "unit": "km"
                }
            }
        ]
    });
    let resp = http().post(&url).json(&body).send().await.ok()?;
    let json: Value = resp.json().await.ok()?;
    json["hits"]["hits"]
        .get(0)?
        .get("_source")?
        .get("parent")
        .cloned()
}

/// Indexes one contribution as a Pelias "venue" place. `_id` is
/// deterministic (`saarathi:venue:{id}`) so a retry or re-approval is a
/// harmless upsert, never a duplicate document.
///
/// `name.default` must be a plain string, not a single-element array —
/// confirmed empirically against this deployment's real Pelias/ES stack:
/// an array-wrapped value indexes fine (same analyzed tokens, matches a
/// direct ES query) but `pelias-api`'s own `/v1/autocomplete` query
/// silently returns zero hits for it, while the identical doc with a bare
/// string is found immediately. Real OSM-imported docs in this index all
/// store it as a bare string too.
pub async fn index_place(es_url: &str, id: Uuid, category: &str, name: &str, lat: f64, lng: f64) {
    // Falls back to the bare `country_a` shape (searchable via a raw ES
    // query, e.g. by `_id`, but not via Pelias autocomplete — see
    // `nearest_parent`'s doc comment) if no nearby doc has admin fields to
    // borrow, rather than failing the whole index write over it.
    let parent = nearest_parent(es_url, lat, lng)
        .await
        .unwrap_or_else(|| json!({ "country_a": ["NPL"] }));
    let doc = json!({
        "name": { "default": name },
        // Pelias's real import pipeline (via `pelias/model`) submits this
        // alongside `name` for every OSM-imported doc — it's `phrase`, not
        // `name`, that `/v1/autocomplete` actually queries (edge-ngram
        // analyzed for as-you-type matching; `/v1/search` queries `name`
        // instead, which is why a doc missing this field is indexed fine,
        // directly fetchable by `_id`, and even found by `/v1/search`, but
        // never appears in the app's autocomplete search box). Confirmed
        // against this deployment's real index mapping: `phrase` has its
        // own per-language field definitions (so it's genuinely populated
        // at write time, not derived), and the mapping's `_source.excludes`
        // deliberately strips it back out of stored `_source` for every
        // doc — which is why it won't show up reading existing OSM-imported
        // docs back either, real or contributed. This write path bypasses
        // `pelias/model` entirely, so nothing else populates it here.
        "phrase": { "default": name },
        "center_point": { "lat": lat, "lon": lng },
        // rides' /v1/geo/search filters results to Nepal by checking
        // exactly this field — omitting it would mean Pelias indexes the
        // doc fine but it never actually surfaces in search.
        "parent": parent,
        "source": "saarathi",
        "source_id": id.to_string(),
        "category": [category],
        "layer": "venue",
    });
    // `?refresh=true` forces this doc's shard to refresh immediately —
    // the index's `refresh_interval` is set to 1m (tuned for the batch
    // OSM/WhosOnFirst importers' write throughput), so without this an
    // approved contribution would silently stay unsearchable for up to a
    // minute, which defeats the point of indexing it at approval time.
    let url = format!(
        "{}/pelias/_doc/saarathi:venue:{id}?refresh=true",
        es_url.trim_end_matches('/')
    );
    match http().put(&url).json(&doc).send().await {
        Ok(resp) if !resp.status().is_success() => {
            tracing::warn!(%id, status = %resp.status(), "pelias index write rejected");
        }
        Err(e) => tracing::warn!(error = %e, %id, "pelias index write failed"),
        Ok(_) => {}
    }
}
