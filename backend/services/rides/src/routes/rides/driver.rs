//! Driver-facing dashboard queries: today's campaign progress and earnings.

use crate::auth::AuthUser;
use crate::error::AppResult;
use crate::state::AppState;
use axum::extract::{Query, State};
use axum::Json;
use rust_decimal::Decimal;
use serde::Deserialize;
use serde::Serialize;
use serde_json::{Value, json};
use uuid::Uuid;

#[derive(sqlx::FromRow)]
struct DriverGoalCampaign {
    id: Uuid,
    title: String,
    kind: String,
    value: Decimal,
    rules: sqlx::types::Json<Vec<crate::rules::CampaignRule>>,
}

/// A driver's progress today toward any live "complete N rides today"
/// campaign — the app-facing counterpart to the automatic bonus payout in
/// `bonus.rs`. Purely informational; the bonus itself is still granted at
/// trip-completion time, not by this endpoint.
pub(super) async fn driver_today(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Value>> {
    let rides_today = crate::rules::rides_today(&st.db, claims.sub, "driver").await;

    let candidates: Vec<DriverGoalCampaign> = sqlx::query_as(
        "SELECT id, title, kind::text, value, rules FROM campaigns \
         WHERE audience = 'driver' AND active = true \
           AND (starts_at IS NULL OR starts_at <= now()) \
           AND (ends_at IS NULL OR ends_at >= now())",
    )
    .fetch_all(&st.db)
    .await?;

    let goals: Vec<Value> = candidates
        .into_iter()
        .filter_map(|c| {
            let target = c.rules.0.iter().find_map(|r| match r {
                crate::rules::CampaignRule::RidesToday { count } => Some(*count),
                _ => None,
            })?;
            Some(json!({
                "campaign_id": c.id,
                "title": c.title,
                "target": target,
                "reward_kind": c.kind,
                "reward_value": c.value,
                "achieved": rides_today >= target,
            }))
        })
        .collect();

    Ok(Json(json!({
        "rides_today": rides_today,
        "goals": goals,
    })))
}

#[derive(Deserialize)]
pub(super) struct EarningsQuery {
    #[serde(default)]
    period: Option<String>,
}

#[derive(Serialize, sqlx::FromRow)]
struct EarningsBucket {
    #[sqlx(rename = "bucket")]
    start: chrono::NaiveDate,
    total: Decimal,
    trips: i64,
}

/// A driver's own earnings (`ledger_entries.driver_payout`), bucketed by
/// Nepal-local day/week/month and gap-filled (a bucket with no trips still
/// appears with `total: 0`, not missing) — same `generate_series` LEFT JOIN
/// shape `metrics.rs`'s admin timeseries endpoint uses, but bucketed on NPT
/// local date (`rules.rs::rides_today`'s pattern) rather than raw UTC,
/// since this is a driver-facing "today/this week" figure. The client
/// derives the trend indicator from the last two buckets itself — no
/// separate current-vs-previous computation needed here.
pub(super) async fn driver_earnings(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Query(q): Query<EarningsQuery>,
) -> AppResult<Json<Value>> {
    let period = q.period.as_deref().unwrap_or("day");
    let sql = match period {
        "week" => {
            "SELECT d::date AS bucket, \
                    COALESCE(SUM(le.driver_payout) FILTER ( \
                        WHERE date_trunc('week', le.created_at AT TIME ZONE 'Asia/Kathmandu')::date = d::date \
                    ), 0) AS total, \
                    COUNT(le.seq) FILTER ( \
                        WHERE date_trunc('week', le.created_at AT TIME ZONE 'Asia/Kathmandu')::date = d::date \
                    ) AS trips \
             FROM generate_series( \
                    date_trunc('week', (now() AT TIME ZONE 'Asia/Kathmandu'))::date - interval '7 weeks', \
                    date_trunc('week', (now() AT TIME ZONE 'Asia/Kathmandu'))::date, \
                    interval '1 week') d \
             LEFT JOIN ledger_entries le \
               ON le.driver_id = $1 \
              AND date_trunc('week', le.created_at AT TIME ZONE 'Asia/Kathmandu')::date \
                    >= date_trunc('week', (now() AT TIME ZONE 'Asia/Kathmandu'))::date - interval '7 weeks' \
             GROUP BY d ORDER BY d"
        }
        "month" => {
            "SELECT d::date AS bucket, \
                    COALESCE(SUM(le.driver_payout) FILTER ( \
                        WHERE date_trunc('month', le.created_at AT TIME ZONE 'Asia/Kathmandu')::date = d::date \
                    ), 0) AS total, \
                    COUNT(le.seq) FILTER ( \
                        WHERE date_trunc('month', le.created_at AT TIME ZONE 'Asia/Kathmandu')::date = d::date \
                    ) AS trips \
             FROM generate_series( \
                    date_trunc('month', (now() AT TIME ZONE 'Asia/Kathmandu'))::date - interval '5 months', \
                    date_trunc('month', (now() AT TIME ZONE 'Asia/Kathmandu'))::date, \
                    interval '1 month') d \
             LEFT JOIN ledger_entries le \
               ON le.driver_id = $1 \
              AND date_trunc('month', le.created_at AT TIME ZONE 'Asia/Kathmandu')::date \
                    >= date_trunc('month', (now() AT TIME ZONE 'Asia/Kathmandu'))::date - interval '5 months' \
             GROUP BY d ORDER BY d"
        }
        _ => {
            "SELECT d::date AS bucket, \
                    COALESCE(SUM(le.driver_payout) FILTER ( \
                        WHERE (le.created_at AT TIME ZONE 'Asia/Kathmandu')::date = d::date \
                    ), 0) AS total, \
                    COUNT(le.seq) FILTER ( \
                        WHERE (le.created_at AT TIME ZONE 'Asia/Kathmandu')::date = d::date \
                    ) AS trips \
             FROM generate_series( \
                    (now() AT TIME ZONE 'Asia/Kathmandu')::date - interval '6 days', \
                    (now() AT TIME ZONE 'Asia/Kathmandu')::date, \
                    interval '1 day') d \
             LEFT JOIN ledger_entries le \
               ON le.driver_id = $1 \
              AND (le.created_at AT TIME ZONE 'Asia/Kathmandu')::date \
                    >= (now() AT TIME ZONE 'Asia/Kathmandu')::date - interval '6 days' \
             GROUP BY d ORDER BY d"
        }
    };

    let buckets: Vec<EarningsBucket> = sqlx::query_as(sql)
        .bind(claims.sub)
        .fetch_all(&st.db)
        .await?;

    Ok(Json(json!({
        "period": period,
        "buckets": buckets,
    })))
}
