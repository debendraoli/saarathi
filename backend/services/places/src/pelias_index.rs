//! Writes approved, navigable place-contributions straight into Pelias's
//! Elasticsearch index — the deployment's `pelias-schema` job creates the
//! stock, unmodified Pelias index/mapping, so a hand-written document in
//! its own base doc shape is indexed and searchable exactly like an
//! OSM-imported one, entirely separate from (and much simpler than) the
//! batch OSM/WhosOnFirst import jobs. Fire-and-forget, same "best effort
//! after commit" convention as `notify::send`/badge awards — a Pelias
//! write hiccup must never fail the staff approval action.

use serde_json::json;
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
    let doc = json!({
        "name": { "default": name },
        "center_point": { "lat": lat, "lon": lng },
        // rides' /v1/geo/search filters results to Nepal by checking
        // exactly this field — omitting it would mean Pelias indexes the
        // doc fine but it never actually surfaces in search.
        "parent": { "country_a": ["NPL"] },
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
