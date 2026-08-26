//! Dispatch & matching (E5): H3-indexed driver presence + the sequential-offer
//! engine. A ride request is offered to the nearest eligible driver with a
//! short TTL; on decline/timeout it moves to the next, widening the search
//! radius. A background loop advances expired offers.
//!
//! Driver presence is indexed by H3 resolution-9 cell (`h3o`, per the Phase 2
//! brief) rather than Redis's built-in GEO commands: each online driver sits
//! in a Redis SET keyed by their current cell (`disp:h3:{cell}`), and a radius
//! search walks `grid_disk(k)` outward from the query point's cell, unions the
//! member sets, then filters/sorts by exact haversine distance — `grid_disk`
//! covers a hexagonal region, not a circle, so the ring count is padded by one
//! and the true circle boundary is enforced afterward, not approximated by it.
//!
//! Presence itself (`disp:meta:{driver_id}`) has no Redis-level TTL, unlike
//! the old GEO-based version: with drivers split across many per-cell keys,
//! TTL-driven expiry would delete the very record (`cell`) needed to clean the
//! right SET up. Instead staleness is checked against `last_seen` in
//! application code (`is_stale`), and cleanup removes from both the meta hash
//! and its cell's SET together.

use crate::state::AppState;
use saarathi_core::geo_h3::{cell_for, rings_for_radius};
use h3o::CellIndex;
use saarathi_core::routing::{haversine_km, LatLng as CoreLatLng, RouteProfile};
use uuid::Uuid;

fn h3_key(cell: CellIndex) -> String {
    format!("disp:h3:{}", u64::from(cell))
}

fn meta_key(driver_id: Uuid) -> String {
    format!("disp:meta:{driver_id}")
}

fn now_ts() -> i64 {
    chrono::Utc::now().timestamp()
}

fn is_stale(last_seen: i64, ttl_secs: i64) -> bool {
    now_ts() - last_seen > ttl_secs
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
    let new_cell = cell_for(lat, lng)?;
    let key = meta_key(driver_id);

    let old_cell: Option<u64> = redis::cmd("HGET")
        .arg(&key)
        .arg("cell")
        .query_async(&mut r)
        .await?;
    if old_cell != Some(u64::from(new_cell)) {
        if let Some(old) = old_cell {
            let _: () = redis::cmd("SREM")
                .arg(format!("disp:h3:{old}"))
                .arg(driver_id.to_string())
                .query_async(&mut r)
                .await
                .unwrap_or(());
        }
        let _: () = redis::cmd("SADD")
            .arg(h3_key(new_cell))
            .arg(driver_id.to_string())
            .query_async(&mut r)
            .await?;
    }

    let _: () = redis::cmd("HSET")
        .arg(&key)
        .arg("job_types")
        .arg(job_types.join(","))
        .arg("last_seen")
        .arg(now_ts())
        .arg("lat")
        .arg(lat)
        .arg("lng")
        .arg(lng)
        .arg("cell")
        .arg(u64::from(new_cell))
        .query_async(&mut r)
        .await?;
    Ok(())
}

pub async fn set_offline(st: &AppState, driver_id: Uuid) -> anyhow::Result<()> {
    let mut r = st.redis.clone();
    remove_driver(&mut r, driver_id).await
}

/// Remove a driver from both the meta hash and their cell's SET.
async fn remove_driver(
    r: &mut redis::aio::ConnectionManager,
    driver_id: Uuid,
) -> anyhow::Result<()> {
    let key = meta_key(driver_id);
    let cell: Option<u64> = redis::cmd("HGET")
        .arg(&key)
        .arg("cell")
        .query_async(r)
        .await?;
    if let Some(cell) = cell {
        let _: () = redis::cmd("SREM")
            .arg(format!("disp:h3:{cell}"))
            .arg(driver_id.to_string())
            .query_async(r)
            .await
            .unwrap_or(());
    }
    let _: () = redis::cmd("DEL").arg(&key).query_async(r).await?;
    Ok(())
}

struct Candidate {
    driver_id: Uuid,
    lat: f64,
    lng: f64,
}

/// Fetch + parse meta for every driver in the H3 disk around `(lat, lng)`,
/// lazily evicting anyone stale, without yet filtering by exact distance.
async fn candidates_in_disk(
    st: &AppState,
    lat: f64,
    lng: f64,
    radius_km: f64,
) -> anyhow::Result<Vec<Candidate>> {
    let mut r = st.redis.clone();
    let center = cell_for(lat, lng)?;
    let k = rings_for_radius(radius_km);
    let disk: Vec<CellIndex> = center.grid_disk(k);

    let mut pipe = redis::pipe();
    for cell in &disk {
        pipe.cmd("SMEMBERS").arg(h3_key(*cell));
    }
    let members_per_cell: Vec<Vec<String>> = pipe.query_async(&mut r).await?;
    let driver_ids: Vec<Uuid> = members_per_cell
        .into_iter()
        .flatten()
        .filter_map(|s| Uuid::parse_str(&s).ok())
        .collect();
    if driver_ids.is_empty() {
        return Ok(Vec::new());
    }

    let mut pipe = redis::pipe();
    for did in &driver_ids {
        pipe.cmd("HMGET")
            .arg(meta_key(*did))
            .arg("lat")
            .arg("lng")
            .arg("last_seen");
    }
    let rows: Vec<(Option<f64>, Option<f64>, Option<i64>)> = pipe.query_async(&mut r).await?;

    let mut out = Vec::with_capacity(driver_ids.len());
    for (driver_id, (lat, lng, last_seen)) in driver_ids.into_iter().zip(rows) {
        match (lat, lng, last_seen) {
            (Some(lat), Some(lng), Some(last_seen)) => {
                if is_stale(last_seen, st.config.presence_ttl_secs) {
                    let _ = remove_driver(&mut r, driver_id).await;
                    continue;
                }
                out.push(Candidate { driver_id, lat, lng });
            }
            // Meta vanished between the SMEMBERS read and this fetch (raced
            // an offline/cleanup) — the SET membership is already stale too.
            _ => continue,
        }
    }
    Ok(out)
}

/// Nearest online drivers (ids) within `radius_km` of a point, nearest first.
async fn nearby(st: &AppState, lng: f64, lat: f64, radius_km: f64) -> anyhow::Result<Vec<Uuid>> {
    let origin = CoreLatLng { lat, lng };
    let mut scored: Vec<(f64, Uuid)> = candidates_in_disk(st, lat, lng, radius_km)
        .await?
        .into_iter()
        .filter_map(|c| {
            let d = haversine_km(origin, CoreLatLng { lat: c.lat, lng: c.lng });
            (d <= radius_km).then_some((d, c.driver_id))
        })
        .collect();
    scored.sort_by(|a, b| a.0.total_cmp(&b.0));
    scored.truncate(10);
    Ok(scored.into_iter().map(|(_, id)| id).collect())
}

/// How many of the haversine-closest drivers get a real routed-ETA lookup —
/// bounds the fan-out of routing-service calls per dispatch pass instead of
/// re-ranking every driver in a wide radius.
const ETA_RERANK_POOL: usize = 15;

/// Like [`nearby`], but re-ranks the haversine-closest pool by actual routed
/// travel time instead of straight-line distance — a driver just across a
/// river, ring-road, or one-way system can be "nearest" as the crow flies yet
/// slowest to actually arrive. Falls back to the haversine estimate wherever
/// `route_path` can't reach the routing service (same degrade-gracefully
/// behavior every other caller of it already relies on), so this never does
/// worse than plain `nearby` — only better when real road data is available.
async fn nearby_by_eta(
    st: &AppState,
    lng: f64,
    lat: f64,
    radius_km: f64,
    profile: RouteProfile,
) -> anyhow::Result<Vec<Uuid>> {
    let origin = CoreLatLng { lat, lng };
    let mut scored: Vec<(f64, Candidate)> = candidates_in_disk(st, lat, lng, radius_km)
        .await?
        .into_iter()
        .filter_map(|c| {
            let d = haversine_km(origin, CoreLatLng { lat: c.lat, lng: c.lng });
            (d <= radius_km).then_some((d, c))
        })
        .collect();
    scored.sort_by(|a, b| a.0.total_cmp(&b.0));
    scored.truncate(ETA_RERANK_POOL);
    if scored.is_empty() {
        return Ok(Vec::new());
    }

    let mut with_eta: Vec<(i32, Uuid)> = futures_util::future::join_all(scored.into_iter().map(
        |(_haversine_km, c)| async move {
            let route = st
                .router
                .route_path(&[CoreLatLng { lat: c.lat, lng: c.lng }, origin], profile)
                .await;
            (route.duration_secs, c.driver_id)
        },
    ))
    .await;
    with_eta.sort_by_key(|(secs, _)| *secs);
    with_eta.truncate(10);
    Ok(with_eta.into_iter().map(|(_, id)| id).collect())
}

/// How many drivers are online within `radius_km` of a point. Used by the surge
/// engine to detect supply scarcity.
pub async fn nearby_count(
    st: &AppState,
    lng: f64,
    lat: f64,
    radius_km: f64,
) -> anyhow::Result<usize> {
    Ok(nearby(st, lng, lat, radius_km).await?.len())
}

/// Approximate positions of online drivers within `radius_km`, for the
/// rider-facing "searching" map animation only — not used for dispatch, so
/// unlike `nearby()` this never returns driver ids, and each point is jittered
/// (~40m) to avoid letting a rider pin a specific driver's exact location by
/// repeatedly polling.
pub async fn nearby_positions(
    st: &AppState,
    lng: f64,
    lat: f64,
    radius_km: f64,
) -> anyhow::Result<Vec<(f64, f64)>> {
    use rand::RngExt;
    let origin = CoreLatLng { lat, lng };
    let candidates = candidates_in_disk(st, lat, lng, radius_km).await?;
    let mut rng = rand::rng();
    let mut out: Vec<(f64, f64)> = candidates
        .into_iter()
        .filter_map(|c| {
            let d = haversine_km(origin, CoreLatLng { lat: c.lat, lng: c.lng });
            if d > radius_km {
                return None;
            }
            // ~0.00036 deg ≈ 40m at this latitude range; good enough for a
            // coarse jitter without needing a proper projection.
            let mut jitter = || rng.random_range(-0.00036..0.00036);
            Some((c.lat + jitter(), c.lng + jitter()))
        })
        .collect();
    out.truncate(25);
    Ok(out)
}

/// A driver is eligible if their heartbeat is fresh and they opted into this job type.
async fn eligible(st: &AppState, driver_id: Uuid, job_type: &str) -> anyhow::Result<bool> {
    let mut r = st.redis.clone();
    let row: (Option<String>, Option<i64>) = redis::cmd("HMGET")
        .arg(meta_key(driver_id))
        .arg("job_types")
        .arg("last_seen")
        .query_async(&mut r)
        .await?;
    match row {
        (Some(jt), Some(last_seen)) => {
            if is_stale(last_seen, st.config.presence_ttl_secs) {
                let _ = remove_driver(&mut r, driver_id).await;
                return Ok(false);
            }
            Ok(jt.split(',').any(|t| t == job_type))
        }
        _ => Ok(false),
    }
}

// ── Dispatch ─────────────────────────────────────────────────────────────────

/// Offer a requested trip to the next-nearest eligible driver. Returns the
/// offered driver, or `None` if none are available yet. Idempotent while an
/// offer is live.
pub async fn dispatch_trip(st: &AppState, trip_id: Uuid) -> anyhow::Result<Option<Uuid>> {
    let trip: Option<(
        String,
        Option<Uuid>,
        f64,
        f64,
        String,
        String,
        Option<f64>,
        String,
        Option<Uuid>,
    )> = sqlx::query_as(
        "SELECT status::text, driver_id, origin_lat, origin_lng, trip_type::text, pricing_mode, \
                search_radius_km, vehicle_class, preferred_driver_id \
         FROM trips WHERE id = $1",
    )
    .bind(trip_id)
    .fetch_optional(&st.db)
    .await?;
    let Some((
        status,
        driver,
        lat,
        lng,
        job_type,
        pricing_mode,
        radius_override,
        vehicle_class,
        preferred_driver_id,
    )) = trip
    else {
        return Ok(None);
    };
    if status != "requested" || driver.is_some() {
        return Ok(None);
    }
    let bid_mode = pricing_mode == "bid";
    let profile = RouteProfile::from_wire(&vehicle_class);

    // Instant mode wants exactly one committed driver, so a live offer means
    // "leave it be" — nothing more to do until it's accepted or expires. Bid
    // mode wants as many bidders as possible, so it keeps inviting eligible
    // drivers who haven't been reached yet on every call instead of stopping
    // once someone's been offered.
    if !bid_mode {
        let live: Option<(Uuid,)> = sqlx::query_as(
            "SELECT id FROM trip_offers WHERE trip_id = $1 AND status = 'offered' AND expires_at > now()",
        )
        .bind(trip_id)
        .fetch_optional(&st.db)
        .await?;
        if live.is_some() {
            return Ok(None);
        }
    }

    // Only a currently-live invite excludes a driver — an *expired* one
    // (they were slow, or briefly out of range) must not permanently rule
    // them out, or a trip with only one nearby driver becomes undispatchable
    // forever the moment that single offer times out.
    let already: Vec<Uuid> = sqlx::query_scalar(
        "SELECT driver_id FROM trip_offers \
         WHERE trip_id = $1 AND status = 'offered' AND expires_at > now()",
    )
    .bind(trip_id)
    .fetch_all(&st.db)
    .await?;

    // A rider explicitly requested this driver (see rides.rs::create /
    // resolve_preferred_driver) — try them alone, once, before falling back
    // to normal radius matching. "Once" = no trip_offers row has ever been
    // created for them on this trip; if they decline/expire, the next
    // dispatch_trip call finds `tried_before == true` and proceeds straight
    // to the normal candidate search like any other driver would.
    let mut preferred_target: Option<Uuid> = None;
    if !bid_mode {
        if let Some(preferred) = preferred_driver_id {
            if !already.contains(&preferred) {
                let tried_before: bool = sqlx::query_scalar(
                    "SELECT EXISTS(SELECT 1 FROM trip_offers WHERE trip_id = $1 AND driver_id = $2)",
                )
                .bind(trip_id)
                .bind(preferred)
                .fetch_one(&st.db)
                .await?;
                if !tried_before && eligible(st, preferred, &job_type).await? {
                    preferred_target = Some(preferred);
                }
            }
        }
    }

    let broadcast: bool;
    let targets: Vec<Uuid>;
    if let Some(preferred) = preferred_target {
        broadcast = false;
        targets = vec![preferred];
    } else {
        // Gather eligible, not-yet-offered drivers, widening the radius until
        // we have more than the broadcast threshold or exhaust the max
        // radius. A re-request's `search_radius_km` override starts wider
        // than the default — and raises the ceiling to match, since a
        // starting radius past the normal max would otherwise make the loop
        // below run zero times.
        let mut radius = radius_override.unwrap_or(st.config.dispatch_radius_km);
        let max_radius = radius_override
            .map(|r| r.max(st.config.dispatch_max_radius_km))
            .unwrap_or(st.config.dispatch_max_radius_km);
        let mut candidates: Vec<Uuid> = Vec::new();
        while radius <= max_radius {
            for did in nearby_by_eta(st, lng, lat, radius, profile).await? {
                if already.contains(&did) || candidates.contains(&did) {
                    continue;
                }
                if !eligible(st, did, &job_type).await? {
                    continue;
                }
                candidates.push(did);
            }
            if candidates.len() > st.config.dispatch_broadcast_threshold {
                break;
            }
            radius *= 2.0;
        }
        if candidates.is_empty() {
            return Ok(None);
        }
        // Blast radius: when supply is thin (few candidates, or drivers going
        // offline), broadcast the offer to all of them at once so a scarce
        // ride is not stuck cycling through sequential timeouts. When supply
        // is plentiful, keep the polite one-at-a-time offer to the nearest
        // driver. Bid mode always broadcasts — an auction needs multiple
        // bidders to be worth anything, so the thin-supply threshold doesn't
        // apply to it.
        broadcast = bid_mode || candidates.len() <= st.config.dispatch_broadcast_threshold;
        targets = if broadcast {
            candidates
        } else {
            candidates[..1].to_vec()
        };
    }

    // Bid-mode invites need to stay visible in the driver's offer list for
    // as long as the auction is realistically open, not the tight 15s
    // instant-offer TTL — the same `SEARCH_TIMEOUT_MINUTES` window the
    // background loop uses as the trip's own give-up backstop. A personally
    // requested driver gets longer than the cold-broadcast TTL too — they
    // deserve more than a few seconds to notice and respond.
    let expires_at = if bid_mode {
        chrono::Utc::now() + chrono::Duration::minutes(SEARCH_TIMEOUT_MINUTES)
    } else if preferred_target.is_some() {
        chrono::Utc::now() + chrono::Duration::seconds((st.config.offer_ttl_secs * 3).max(60))
    } else {
        chrono::Utc::now() + chrono::Duration::seconds(st.config.offer_ttl_secs)
    };
    let offer_title = if preferred_target.is_some() {
        "A rider requested you personally"
    } else if job_type == "delivery" {
        "New delivery request nearby"
    } else {
        "New ride request nearby"
    };

    // Multiple independent triggers (trip creation, decline_offer, change_ask,
    // the background tick) can all call dispatch_trip for the same trip close
    // together. Everything above this point reads without a lock, so two
    // overlapping calls can both compute a candidate set before either has
    // inserted an offer. Serialize per-trip right before the actual insert —
    // re-checking live-offer state fresh under the lock — so they can't both
    // create one (same pattern as ledger::append's global lock, keyed by trip
    // instead of a fixed constant).
    let mut tx = st.db.begin().await?;
    sqlx::query("SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))")
        .bind(trip_id)
        .execute(&mut *tx)
        .await?;
    if !bid_mode {
        let live: Option<(Uuid,)> = sqlx::query_as(
            "SELECT id FROM trip_offers WHERE trip_id = $1 AND status = 'offered' AND expires_at > now()",
        )
        .bind(trip_id)
        .fetch_optional(&mut *tx)
        .await?;
        if live.is_some() {
            // Another call won the race and already offered this trip.
            return Ok(None);
        }
    }
    let already_now: Vec<Uuid> = sqlx::query_scalar(
        "SELECT driver_id FROM trip_offers \
         WHERE trip_id = $1 AND status = 'offered' AND expires_at > now()",
    )
    .bind(trip_id)
    .fetch_all(&mut *tx)
    .await?;
    let targets: Vec<Uuid> = targets
        .iter()
        .copied()
        .filter(|d| !already_now.contains(d))
        .collect();
    if targets.is_empty() {
        return Ok(None);
    }
    for &did in &targets {
        sqlx::query("INSERT INTO trip_offers (trip_id, driver_id, expires_at) VALUES ($1, $2, $3)")
            .bind(trip_id)
            .bind(did)
            .bind(expires_at)
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;

    for &did in &targets {
        // Published on the *driver's* own channel (see `driver_ws.rs`), not
        // the trip's — a driver being offered this trip has no reason to
        // already be connected to a WebSocket scoped to a trip they don't
        // know exists yet. The driver-scoped socket is instead connected for
        // as long as the driver app considers itself online, exactly so
        // this reaches it immediately instead of waiting on the fallback
        // poll below to notice.
        st.hub.publish(
            "driver",
            did,
            serde_json::json!({
                "type": "offer",
                "trip_id": trip_id,
                "driver_id": did,
                "expires_at": expires_at.to_rfc3339(),
                "broadcast": broadcast,
            })
            .to_string(),
        );
        // The WebSocket event above only reaches a driver whose app is
        // foregrounded — push so a backgrounded/killed app still learns
        // about the offer (falls back to SMS too, TRANSACTIONAL is in the
        // CRITICAL class set).
        crate::notify::send(
            &st.nats,
            did,
            saarathi_core::domain::notif::TRANSACTIONAL,
            offer_title,
            "Open the app to respond before it expires.",
            None,
        )
        .await;
    }
    Ok(Some(targets[0]))
}

/// Background loop: expire stale offers and (re)dispatch waiting trips.
/// How long a trip stays in the matching pool before giving up. Past this, a
/// still-unmatched trip used to just silently fall out of the dispatcher's
/// polling query and sit at `requested` forever — the app's "no driver
/// found" UI (`TripStatus.noDriver`) had nothing that ever set it. Now it's
/// explicitly cancelled so the rider sees that state and (since the
/// one-active-ride guard landed) can request again instead of being stuck.
const SEARCH_TIMEOUT_MINUTES: i64 = 10;

pub async fn run_dispatcher(st: AppState) {
    let mut tick = tokio::time::interval(std::time::Duration::from_secs(3));
    loop {
        tick.tick().await;
        // Circuit breaker: ops can freeze matching from the dashboard.
        if !crate::flags::is_enabled(&st, crate::flags::DISPATCH, true).await {
            continue;
        }
        if let Err(e) = sqlx::query(
            "UPDATE trip_offers SET status = 'expired' WHERE status = 'offered' AND expires_at <= now()",
        )
        .execute(&st.db)
        .await
        {
            tracing::warn!(error = %e, "dispatch tick: offer expiry sweep failed");
        }
        // Same idea for individual bids: `list_bids` already filters on
        // `expires_at`, so this doesn't change what the rider sees, but a
        // driver's expired bid should read as 'expired', not sit at 'live'
        // forever — and it frees the one-live-bid-per-driver slot for a
        // fresh bid without relying on the upsert's ON CONFLICT alone.
        if let Err(e) = sqlx::query(
            "UPDATE trip_bids SET status = 'expired' WHERE status = 'live' AND expires_at <= now()",
        )
        .execute(&st.db)
        .await
        {
            tracing::warn!(error = %e, "dispatch tick: bid expiry sweep failed");
        }

        let timed_out: Vec<(Uuid, Uuid)> = sqlx::query_as(
            "UPDATE trips SET status = 'cancelled', cancel_reason = 'no_driver_available', \
                 cancelled_by_role = 'system', updated_at = now() \
             WHERE status = 'requested' AND driver_id IS NULL \
               AND created_at <= now() - make_interval(mins => $1) \
             RETURNING id, rider_id",
        )
        .bind(SEARCH_TIMEOUT_MINUTES as i32)
        .fetch_all(&st.db)
        .await
        .unwrap_or_else(|e| {
            tracing::warn!(error = %e, "dispatch tick: search-timeout sweep failed");
            Vec::new()
        });
        for (tid, rider_id) in timed_out {
            crate::notify::send(
                &st.nats,
                rider_id,
                saarathi_core::domain::notif::TRANSACTIONAL,
                "No driver found",
                "We couldn't find a nearby driver for your trip. Please try requesting again.",
                None,
            )
            .await;
            tracing::info!(trip = %tid, "dispatch: search timed out, cancelled");
        }

        let waiting: Vec<Uuid> = sqlx::query_scalar(
            "SELECT t.id FROM trips t \
             WHERE t.status = 'requested' AND t.driver_id IS NULL \
               AND t.created_at > now() - make_interval(mins => $1) \
               AND NOT EXISTS ( \
                   SELECT 1 FROM trip_offers o \
                   WHERE o.trip_id = t.id AND o.status = 'offered' AND o.expires_at > now()) \
             LIMIT 20",
        )
        .bind(SEARCH_TIMEOUT_MINUTES as i32)
        .fetch_all(&st.db)
        .await
        .unwrap_or_else(|e| {
            tracing::warn!(error = %e, "dispatch tick: waiting-trips query failed");
            Vec::new()
        });

        for tid in waiting {
            if let Err(e) = dispatch_trip(&st, tid).await {
                tracing::warn!(trip = %tid, error = %e, "dispatch tick failed");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_stale_respects_the_ttl_boundary() {
        let now = now_ts();
        assert!(!is_stale(now, 60));
        assert!(!is_stale(now - 59, 60));
        assert!(is_stale(now - 61, 60));
    }

    /// The acceptance criterion this satisfies: seed a small H3 grid of known
    /// driver positions and confirm a radius search returns exactly the
    /// expected set — near points included, far points excluded — using the
    /// same disk-walk + exact-distance-filter logic `nearby()` uses, without
    /// needing a live Redis (this exercises the pure cell/ring/distance math
    /// directly; `nearby()` itself is covered live via `scripts/smoke.sh`).
    #[test]
    fn seeded_grid_radius_search_returns_the_correct_set() {
        // Ghorahi-ish origin. Points at increasing offsets from it.
        let origin = (28.0336, 82.4836);
        let near = (28.0350, 82.4850); // ~0.2km away
        let mid = (28.0450, 82.4950); // ~1.5km away
        let far = (28.1200, 82.5600); // ~10km away

        let radius_km = 2.0;
        let center = cell_for(origin.0, origin.1).unwrap();
        let k = rings_for_radius(radius_km);
        let disk: std::collections::HashSet<CellIndex> =
            center.grid_disk::<Vec<CellIndex>>(k).into_iter().collect();

        for (label, (plat, plng), expect_in_disk) in [
            ("near", near, true),
            ("mid", mid, true),
            ("far", far, false),
        ] {
            let cell = cell_for(plat, plng).unwrap();
            assert_eq!(
                disk.contains(&cell),
                expect_in_disk,
                "{label} point's cell membership in the disk"
            );
        }

        // And the exact-distance filter (what `nearby()` applies after the
        // disk walk) correctly excludes anything the hex disk over-covers.
        let o = CoreLatLng { lat: origin.0, lng: origin.1 };
        for (label, (plat, plng), expect_within_radius) in [
            ("near", near, true),
            ("mid", mid, true),
            ("far", far, false),
        ] {
            let d = haversine_km(o, CoreLatLng { lat: plat, lng: plng });
            assert_eq!(
                d <= radius_km,
                expect_within_radius,
                "{label} point at {d:.2}km"
            );
        }
    }
}
