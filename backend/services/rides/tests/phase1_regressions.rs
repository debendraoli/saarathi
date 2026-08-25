//! Integration tests for the Phase 1 backend-refactor fixes (see
//! `keen-juggling-hopper.md`). Runs against the real Postgres the local
//! `docker compose` stack uses (`DATABASE_URL` from `backend/.env`, found by
//! walking up from this crate) — these are concurrency regressions that a
//! mocked-DB unit test can't catch.
//!
//! Each test signs its own JWT with the shared `JWT_SECRET` instead of going
//! through the auth service's OTP flow — `AuthUser` only verifies the
//! signature, and `trips`/`credit_accounts` have no FK back to a real `users`
//! row, so a self-signed token for a fresh random UUID is a valid, isolated
//! fixture per test run.
//!
//! Run with `cargo test -p saarathi-rides --test phase1_regressions -- --test-threads=1`.
//! Each test calls `bootstrap`, which re-applies `schema.sql`'s idempotent
//! DDL (`CREATE ... IF NOT EXISTS`, guarded `ALTER TABLE ADD CONSTRAINT`) —
//! running that concurrently from multiple test threads against the same
//! Postgres deadlocks (observed directly: default parallel `cargo test`
//! reliably hits "deadlock detected" here), so these must run serially.

use chrono::Utc;
use jsonwebtoken::{encode, EncodingKey, Header};
use rust_decimal_macros::dec;
use saarathi_rides::{bootstrap, config::Config, routes, state::AppState};
use serde::Serialize;
use serde_json::{json, Value};
use sqlx::Row;
use std::net::SocketAddr;
use uuid::Uuid;

#[derive(Serialize)]
struct Claims {
    sub: Uuid,
    role: String,
    iat: i64,
    exp: i64,
}

fn token(secret: &str, sub: Uuid, role: &str) -> String {
    let now = Utc::now().timestamp();
    let claims = Claims {
        sub,
        role: role.into(),
        iat: now,
        exp: now + 3600,
    };
    encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )
    .unwrap()
}

/// Boots a real AppState (real Postgres/Redis; NATS best-effort) and serves
/// the real router on an OS-assigned localhost port.
async fn spawn_app() -> (SocketAddr, AppState) {
    dotenvy::dotenv().ok();
    let mut config = Config::from_env().expect(
        "DATABASE_URL/JWT_SECRET missing — run these tests with the docker-compose stack up \
         (backend/.env is picked up automatically)",
    );
    config.port = 0;
    let state = bootstrap(config).await.expect("bootstrap AppState");
    let app = routes::router(state.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    (addr, state)
}

fn ride_body() -> Value {
    json!({
        "origin": {"lat": 27.7172, "lng": 85.3240},
        "dest": {"lat": 27.7000, "lng": 85.3000},
        "vehicle_class": "two_wheeler",
        "payment_method": "cash",
    })
}

/// Phase 1 item 2: POST /v1/rides requires X-Idempotency-Key, and replaying
/// the same key returns the original trip instead of booking a second one.
#[tokio::test]
async fn idempotency_key_replays_same_trip_not_a_duplicate() {
    let (addr, state) = spawn_app().await;
    let base = format!("http://{addr}");
    let jwt = token(&state.config.jwt_secret, Uuid::new_v4(), "rider");
    let client = reqwest::Client::new();

    // Missing header -> 400, no trip created.
    let res = client
        .post(format!("{base}/v1/rides"))
        .bearer_auth(&jwt)
        .json(&ride_body())
        .send()
        .await
        .unwrap();
    assert_eq!(res.status(), 400);

    let key = format!("test-key-{}", Uuid::new_v4());
    let first: Value = client
        .post(format!("{base}/v1/rides"))
        .bearer_auth(&jwt)
        .header("x-idempotency-key", &key)
        .json(&ride_body())
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let trip_id = first["id"].as_str().unwrap().to_string();

    let replay: Value = client
        .post(format!("{base}/v1/rides"))
        .bearer_auth(&jwt)
        .header("x-idempotency-key", &key)
        .json(&ride_body())
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(replay["id"].as_str().unwrap(), trip_id, "replay must return the same trip, not a new one");

    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM trips WHERE id = $1")
        .bind(Uuid::parse_str(&trip_id).unwrap())
        .fetch_one(&state.db)
        .await
        .unwrap();
    assert_eq!(count, 1, "exactly one trip row must exist for this booking attempt");

    sqlx::query("DELETE FROM trips WHERE id = $1")
        .bind(Uuid::parse_str(&trip_id).unwrap())
        .execute(&state.db)
        .await
        .unwrap();
    sqlx::query("DELETE FROM idempotency_keys WHERE key = $1")
        .bind(&key)
        .execute(&state.db)
        .await
        .unwrap();
}

/// Phase 1 item 3: two concurrent accept_offer calls for the *same driver*
/// on two *different* trips must not both succeed — trips_driver_one_active_idx
/// is the hard backstop behind the racy application-level check.
#[tokio::test]
async fn concurrent_accept_offer_enforces_one_active_trip_per_driver() {
    let (addr, state) = spawn_app().await;
    let base = format!("http://{addr}");
    let driver = Uuid::new_v4();
    let jwt = token(&state.config.jwt_secret, driver, "driver");

    sqlx::query(
        "INSERT INTO credit_accounts (user_id, kind, balance) VALUES ($1, 'driver', 100)",
    )
    .bind(driver)
    .execute(&state.db)
    .await
    .unwrap();

    let mut trip_ids = Vec::new();
    for _ in 0..2 {
        let row = sqlx::query(
            "INSERT INTO trips (rider_id, vehicle_class, origin_lat, origin_lng, dest_lat, dest_lng, \
                distance_km, duration_secs, gross_fare, final_fare, commission, accident_fund, \
                driver_payout, payment_method) \
             VALUES ($1,'two_wheeler',27.7,85.3,27.71,85.31,1,60,100,100,10,1,89,'cash') RETURNING id",
        )
        .bind(Uuid::new_v4())
        .fetch_one(&state.db)
        .await
        .unwrap();
        let trip_id: Uuid = row.get(0);
        sqlx::query(
            "INSERT INTO trip_offers (trip_id, driver_id, expires_at) \
             VALUES ($1, $2, now() + interval '5 minutes')",
        )
        .bind(trip_id)
        .bind(driver)
        .execute(&state.db)
        .await
        .unwrap();
        trip_ids.push(trip_id);
    }

    let client = reqwest::Client::new();
    let (r1, r2) = tokio::join!(
        client
            .post(format!("{base}/v1/rides/{}/offer/accept", trip_ids[0]))
            .bearer_auth(&jwt)
            .send(),
        client
            .post(format!("{base}/v1/rides/{}/offer/accept", trip_ids[1]))
            .bearer_auth(&jwt)
            .send(),
    );
    let statuses = [r1.unwrap().status(), r2.unwrap().status()];
    let successes = statuses.iter().filter(|s| s.is_success()).count();
    assert_eq!(successes, 1, "exactly one of the two concurrent accepts must win: {statuses:?}");
    let conflicts = statuses.iter().filter(|s| s.as_u16() == 409).count();
    assert_eq!(conflicts, 1, "the loser must see a 409 conflict, not a 5xx: {statuses:?}");

    let active: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM trips WHERE driver_id = $1 AND status IN ('accepted','arriving','in_progress')",
    )
    .bind(driver)
    .fetch_one(&state.db)
    .await
    .unwrap();
    assert_eq!(active, 1, "driver must end up with exactly one active trip");

    sqlx::query("DELETE FROM trip_offers WHERE trip_id = ANY($1)")
        .bind(&trip_ids)
        .execute(&state.db)
        .await
        .unwrap();
    sqlx::query("DELETE FROM trips WHERE id = ANY($1)")
        .bind(&trip_ids)
        .execute(&state.db)
        .await
        .unwrap();
    sqlx::query("DELETE FROM credit_accounts WHERE user_id = $1")
        .bind(driver)
        .execute(&state.db)
        .await
        .unwrap();
}

/// Phase 1 item 4: two concurrent debits against the same partner wallet must
/// not both succeed past the balance floor — `partner_ledger::append` holds
/// its advisory lock across the check-then-write.
#[tokio::test]
async fn concurrent_partner_ledger_debit_rejects_overdraft() {
    dotenvy::dotenv().ok();
    let config = Config::from_env().expect("DATABASE_URL/JWT_SECRET missing");
    let pool = sqlx::PgPool::connect(&config.database_url).await.unwrap();
    saarathi_rides::db::init_schema(&pool).await.unwrap();

    let partner_id = Uuid::new_v4();
    sqlx::query("INSERT INTO partner_wallets (partner_id, balance) VALUES ($1, 100)")
        .bind(partner_id)
        .execute(&pool)
        .await
        .unwrap();

    let debit = |pool: sqlx::PgPool| async move {
        let mut tx = pool.begin().await.unwrap();
        let res =
            saarathi_core::partner_ledger::append(&mut tx, partner_id, None, "ride_charge", -dec!(80))
                .await;
        if res.is_ok() {
            tx.commit().await.unwrap();
        }
        res
    };
    let (r1, r2) = tokio::join!(debit(pool.clone()), debit(pool.clone()));
    let successes = [r1.is_ok(), r2.is_ok()].iter().filter(|x| **x).count();
    assert_eq!(successes, 1, "only one of the two 80-unit debits against a 100-unit balance may succeed");

    let balance: rust_decimal::Decimal =
        sqlx::query_scalar("SELECT balance FROM partner_wallets WHERE partner_id = $1")
            .bind(partner_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(balance >= rust_decimal::Decimal::ZERO, "balance must never go negative, got {balance}");

    sqlx::query("DELETE FROM partner_wallets WHERE partner_id = $1")
        .bind(partner_id)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("DELETE FROM partner_ledger WHERE partner_id = $1")
        .bind(partner_id)
        .execute(&pool)
        .await
        .unwrap();
}
