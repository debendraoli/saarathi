//! Token-bucket OTP rate limiting, keyed by both client IP and phone number —
//! either bucket running dry blocks the request (brief: "3 requests / 10 min,
//! keyed by both IP and phone number, either limit trips should block").
//!
//! Redis-backed so it's shared across pods; a single Lua script checks *and*
//! consumes both buckets atomically, so a request that would exhaust one
//! bucket never partially consumes the other. Standard continuous-refill
//! token bucket: each key holds `(tokens, last_refill_unix)`, refilled by
//! elapsed-time × rate on every check, capped at `capacity`.
//!
//! This is a defense-in-depth *addition* alongside the existing coarser
//! phone-only hourly limit in `otp_codes` (see `routes::auth_routes`) — it
//! catches rapid bursts from one IP or phone that the hourly check alone
//! would let through until the count climbed.

use redis::aio::ConnectionManager;
use redis::Script;

/// 3 requests per rolling 10-minute window.
const CAPACITY: f64 = 3.0;
const WINDOW_SECS: f64 = 600.0;
const REFILL_PER_SEC: f64 = CAPACITY / WINDOW_SECS;

// KEYS[1] = ip bucket key, KEYS[2] = phone bucket key
// ARGV[1] = capacity, ARGV[2] = refill_per_sec, ARGV[3] = now (unix secs), ARGV[4] = ttl_secs
//
// Refills both buckets to `now`, then only consumes 1 token from each if
// *both* have at least 1 available — otherwise neither is touched, so a
// blocked request doesn't burn the other key's quota.
const TOKEN_BUCKET_SCRIPT: &str = r#"
local function refill(key, capacity, rate, now)
    local data = redis.call('HMGET', key, 'tokens', 'ts')
    local tokens = tonumber(data[1])
    local ts = tonumber(data[2])
    if tokens == nil then
        tokens = capacity
        ts = now
    end
    local delta = now - ts
    if delta < 0 then delta = 0 end
    tokens = math.min(capacity, tokens + delta * rate)
    return tokens
end

local capacity = tonumber(ARGV[1])
local rate = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local ttl = tonumber(ARGV[4])

local ip_tokens = refill(KEYS[1], capacity, rate, now)
local phone_tokens = refill(KEYS[2], capacity, rate, now)

if ip_tokens < 1 or phone_tokens < 1 then
    redis.call('HMSET', KEYS[1], 'tokens', ip_tokens, 'ts', now)
    redis.call('EXPIRE', KEYS[1], ttl)
    redis.call('HMSET', KEYS[2], 'tokens', phone_tokens, 'ts', now)
    redis.call('EXPIRE', KEYS[2], ttl)
    return 0
end

ip_tokens = ip_tokens - 1
phone_tokens = phone_tokens - 1
redis.call('HMSET', KEYS[1], 'tokens', ip_tokens, 'ts', now)
redis.call('EXPIRE', KEYS[1], ttl)
redis.call('HMSET', KEYS[2], 'tokens', phone_tokens, 'ts', now)
redis.call('EXPIRE', KEYS[2], ttl)
return 1
"#;

// Single-bucket variant of the same refill algorithm, for the allowlisted-IP
// path below (KEYS[1] only). Duplicated rather than shared with the two-key
// script above — Lua has no cheap cross-script sharing here, and it's ~15 lines.
const SINGLE_BUCKET_SCRIPT: &str = r#"
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local rate = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local ttl = tonumber(ARGV[4])

local data = redis.call('HMGET', key, 'tokens', 'ts')
local tokens = tonumber(data[1])
local ts = tonumber(data[2])
if tokens == nil then
    tokens = capacity
    ts = now
end
local delta = now - ts
if delta < 0 then delta = 0 end
tokens = math.min(capacity, tokens + delta * rate)

if tokens < 1 then
    redis.call('HMSET', key, 'tokens', tokens, 'ts', now)
    redis.call('EXPIRE', key, ttl)
    return 0
end

tokens = tokens - 1
redis.call('HMSET', key, 'tokens', tokens, 'ts', now)
redis.call('EXPIRE', key, ttl)
return 1
"#;

/// Returns `true` if the request is allowed (and consumes a token from both
/// buckets), `false` if either bucket is dry. On a Redis error, logs and
/// **fails open** — an infra hiccup here shouldn't take down OTP requests
/// platform-wide; the existing DB-based hourly limit still applies.
///
/// If `ip` is in `ip_allowlist` (or the allowlist contains the wildcard `*`
/// — meant for local dev/CI, where the source is a single, unpredictable
/// Docker-bridge address shared by many simulated users), the IP bucket is
/// skipped entirely and only the phone bucket is checked. The phone bucket
/// always applies regardless, so a single number still can't be OTP-bombed
/// through an allowlisted address.
pub async fn check(
    redis: &mut ConnectionManager,
    ip: &str,
    phone: &str,
    ip_allowlist: &[String],
) -> bool {
    let now = chrono::Utc::now().timestamp() as f64;
    let ttl_secs = (CAPACITY / REFILL_PER_SEC).ceil() as i64 + 60;

    let result: redis::RedisResult<i32> = if ip_allowlist.iter().any(|a| a == "*" || a == ip) {
        Script::new(SINGLE_BUCKET_SCRIPT)
            .key(format!("otpq:phone:{phone}"))
            .arg(CAPACITY)
            .arg(REFILL_PER_SEC)
            .arg(now)
            .arg(ttl_secs)
            .invoke_async(redis)
            .await
    } else {
        Script::new(TOKEN_BUCKET_SCRIPT)
            .key(format!("otpq:ip:{ip}"))
            .key(format!("otpq:phone:{phone}"))
            .arg(CAPACITY)
            .arg(REFILL_PER_SEC)
            .arg(now)
            .arg(ttl_secs)
            .invoke_async(redis)
            .await
    };

    match result {
        Ok(1) => true,
        Ok(_) => false,
        Err(e) => {
            tracing::warn!(error = %e, "otp rate limiter redis error — failing open");
            true
        }
    }
}
