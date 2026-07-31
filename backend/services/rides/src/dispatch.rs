//! Dispatch & matching (E5): Redis-backed driver presence + geo-index, and the
//! sequential-offer engine. A ride request is offered to the nearest eligible
//! driver with a short TTL; on decline/timeout it moves to the next, widening
//! the search radius. A background loop advances expired offers.

use crate::state::AppState;
use uuid::Uuid;

const GEO_KEY: &str = "disp:drivers";

fn meta_key(driver_id: Uuid) -> String {
    format!("disp:meta:{driver_id}")
}

fn now_ts() -> i64 {
    chrono::Utc::now().timestamp()
}

// ── Presence ─────────────────────────────────────────────────────────────────

/// Put a driver on the map (or refresh position + heartbeat).
pub async fn set_online(
    st: &AppState,
    driver_id: Uuid,
    lat: f64,
    lng: f64,
    job_types: &[String],
) -> anyhow::Result<()> {
    let mut r = st.redis.clone();
    let member = driver_id.to_string();
    let _: () = redis::cmd("GEOADD")
        .arg(GEO_KEY)
        .arg(lng)
        .arg(lat)
        .arg(&member)
        .query_async(&mut r)
        .await?;
    let key = meta_key(driver_id);
    let _: () = redis::cmd("HSET")
        .arg(&key)
        .arg("job_types")
        .arg(job_types.join(","))
        .arg("last_seen")
        .arg(now_ts())
        .query_async(&mut r)
        .await?;
    let _: () = redis::cmd("EXPIRE")
        .arg(&key)
        .arg(st.config.presence_ttl_secs)
        .query_async(&mut r)
        .await?;
    Ok(())
}

pub async fn set_offline(st: &AppState, driver_id: Uuid) -> anyhow::Result<()> {
    let mut r = st.redis.clone();
    let member = driver_id.to_string();
    let _: () = redis::cmd("ZREM")
        .arg(GEO_KEY)
        .arg(&member)
        .query_async(&mut r)
        .await?;
    let _: () = redis::cmd("DEL")
        .arg(meta_key(driver_id))
        .query_async(&mut r)
        .await?;
    Ok(())
}

/// Nearest online drivers (ids) within `radius_km` of a point, nearest first.
async fn nearby(st: &AppState, lng: f64, lat: f64, radius_km: f64) -> anyhow::Result<Vec<Uuid>> {
    let mut r = st.redis.clone();
    let ids: Vec<String> = redis::cmd("GEOSEARCH")
        .arg(GEO_KEY)
        .arg("FROMLONLAT")
        .arg(lng)
        .arg(lat)
        .arg("BYRADIUS")
        .arg(radius_km)
        .arg("km")
        .arg("ASC")
        .arg("COUNT")
        .arg(10)
        .query_async(&mut r)
        .await?;
    Ok(ids.iter().filter_map(|s| Uuid::parse_str(s).ok()).collect())
}

/// A driver is eligible if their heartbeat is fresh and they opted into this job type.
async fn eligible(st: &AppState, driver_id: Uuid, job_type: &str) -> anyhow::Result<bool> {
    let mut r = st.redis.clone();
    let job_types: Option<String> = redis::cmd("HGET")
        .arg(meta_key(driver_id))
        .arg("job_types")
        .query_async(&mut r)
        .await?;
    match job_types {
        Some(jt) => Ok(jt.split(',').any(|t| t == job_type)),
        None => {
            // Stale heartbeat expired — drop them from the geo-index lazily.
            let _: () = redis::cmd("ZREM")
                .arg(GEO_KEY)
                .arg(driver_id.to_string())
                .query_async(&mut r)
                .await
                .unwrap_or(());
            Ok(false)
        }
    }
}

// ── Dispatch ─────────────────────────────────────────────────────────────────

/// Offer a requested trip to the next-nearest eligible driver. Returns the
/// offered driver, or `None` if none are available yet. Idempotent while an
/// offer is live.
pub async fn dispatch_trip(st: &AppState, trip_id: Uuid) -> anyhow::Result<Option<Uuid>> {
    let trip: Option<(String, Option<Uuid>, f64, f64, String)> = sqlx::query_as(
        "SELECT status::text, driver_id, origin_lat, origin_lng, trip_type::text \
         FROM trips WHERE id = $1",
    )
    .bind(trip_id)
    .fetch_optional(&st.db)
    .await?;
    let Some((status, driver, lat, lng, job_type)) = trip else {
        return Ok(None);
    };
    if status != "requested" || driver.is_some() {
        return Ok(None);
    }

    // Already have a live offer? Leave it be.
    let live: Option<(Uuid,)> = sqlx::query_as(
        "SELECT id FROM trip_offers WHERE trip_id = $1 AND status = 'offered' AND expires_at > now()",
    )
    .bind(trip_id)
    .fetch_optional(&st.db)
    .await?;
    if live.is_some() {
        return Ok(None);
    }

    let already: Vec<Uuid> =
        sqlx::query_scalar("SELECT driver_id FROM trip_offers WHERE trip_id = $1")
            .bind(trip_id)
            .fetch_all(&st.db)
            .await?;

    let mut radius = st.config.dispatch_radius_km;
    while radius <= st.config.dispatch_max_radius_km {
        for did in nearby(st, lng, lat, radius).await? {
            if already.contains(&did) {
                continue;
            }
            if !eligible(st, did, &job_type).await? {
                continue;
            }
            let expires_at =
                chrono::Utc::now() + chrono::Duration::seconds(st.config.offer_ttl_secs);
            sqlx::query(
                "INSERT INTO trip_offers (trip_id, driver_id, expires_at) VALUES ($1, $2, $3)",
            )
            .bind(trip_id)
            .bind(did)
            .bind(expires_at)
            .execute(&st.db)
            .await?;
            st.hub.publish(
                trip_id,
                serde_json::json!({
                    "type": "offer",
                    "trip_id": trip_id,
                    "driver_id": did,
                    "expires_at": expires_at.to_rfc3339(),
                })
                .to_string(),
            );
            return Ok(Some(did));
        }
        radius *= 2.0;
    }
    Ok(None)
}

/// Background loop: expire stale offers and (re)dispatch waiting trips.
pub async fn run_dispatcher(st: AppState) {
    let mut tick = tokio::time::interval(std::time::Duration::from_secs(3));
    loop {
        tick.tick().await;
        let _ = sqlx::query(
            "UPDATE trip_offers SET status = 'expired' WHERE status = 'offered' AND expires_at <= now()",
        )
        .execute(&st.db)
        .await;

        let waiting: Vec<Uuid> = sqlx::query_scalar(
            "SELECT t.id FROM trips t \
             WHERE t.status = 'requested' AND t.driver_id IS NULL \
               AND t.created_at > now() - interval '10 minutes' \
               AND NOT EXISTS ( \
                   SELECT 1 FROM trip_offers o \
                   WHERE o.trip_id = t.id AND o.status = 'offered' AND o.expires_at > now()) \
             LIMIT 20",
        )
        .fetch_all(&st.db)
        .await
        .unwrap_or_default();

        for tid in waiting {
            if let Err(e) = dispatch_trip(&st, tid).await {
                tracing::warn!(trip = %tid, error = %e, "dispatch tick failed");
            }
        }
    }
}
