//! Rider-facing self-service: trusted contacts (safety) and the rider's own
//! ride index (a plain-language cancellation-rate readout, not the ops-only
//! aggregate `metrics.rs`/`insights.rs` expose).

use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{routing::get, Json, Router};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

// Deliberately not under `/v1/me/*` — the gateway already routes that whole
// prefix to the auth service (see traefik/dynamic/routes.yml), and this data
// lives in the rides service's own database.
pub fn routes() -> Router<AppState> {
    Router::new()
        .route(
            "/v1/trusted-contacts",
            get(list_contacts).post(add_contact),
        )
        .route("/v1/trusted-contacts/{id}", axum::routing::delete(remove_contact))
        .route("/v1/ride-index", get(ride_index))
}

#[derive(Serialize, sqlx::FromRow)]
struct TrustedContact {
    id: Uuid,
    name: String,
    phone: String,
    created_at: DateTime<Utc>,
}

async fn list_contacts(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Vec<TrustedContact>>> {
    let rows: Vec<TrustedContact> = sqlx::query_as(
        "SELECT id, name, phone, created_at FROM trusted_contacts \
         WHERE user_id = $1 ORDER BY created_at ASC",
    )
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
struct NewContact {
    name: String,
    phone: String,
}

async fn add_contact(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(b): Json<NewContact>,
) -> AppResult<Json<TrustedContact>> {
    let name = b.name.trim();
    let phone = b.phone.trim();
    if name.is_empty() || phone.is_empty() {
        return Err(AppError::BadRequest("name and phone are required".into()));
    }
    let existing: i64 =
        sqlx::query_scalar("SELECT count(*) FROM trusted_contacts WHERE user_id = $1")
            .bind(claims.sub)
            .fetch_one(&st.db)
            .await?;
    // A short, hand-curated list (emergency contacts, not an address book) —
    // caps it well above what anyone would realistically need so the limit
    // never gets in the way, just guards against unbounded growth.
    if existing >= 10 {
        return Err(AppError::BadRequest("trusted contact limit reached".into()));
    }
    let row: TrustedContact = sqlx::query_as(
        "INSERT INTO trusted_contacts (user_id, name, phone) VALUES ($1, $2, $3) \
         RETURNING id, name, phone, created_at",
    )
    .bind(claims.sub)
    .bind(name)
    .bind(phone)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(row))
}

async fn remove_contact(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<serde_json::Value>> {
    let res = sqlx::query("DELETE FROM trusted_contacts WHERE id = $1 AND user_id = $2")
        .bind(id)
        .bind(claims.sub)
        .execute(&st.db)
        .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::NotFound);
    }
    Ok(Json(json!({ "ok": true })))
}

/// A plain-language readout of the rider's own cancellation behaviour — a
/// green/yellow/red band, not a raw percentage, since the point is "are you
/// in the zone that risks a platform warning," not a precise number.
/// Thresholds deliberately looser than any internal ops threshold: this is
/// meant to reassure a normal rider, not alarm them over one bad day.
async fn ride_index(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<serde_json::Value>> {
    let (total, cancelled_by_rider): (i64, i64) = sqlx::query_as(
        "SELECT count(*), \
                count(*) FILTER (WHERE status = 'cancelled' AND cancelled_by_role = 'rider') \
         FROM trips WHERE rider_id = $1 AND status IN ('completed', 'cancelled')",
    )
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await?;

    let rate = if total > 0 {
        cancelled_by_rider as f64 / total as f64
    } else {
        0.0
    };
    // Too few rides to say anything meaningful either way — one cancelled
    // trip out of two looks alarming as a raw rate but isn't a pattern yet.
    let level = if total < 5 || rate <= 0.15 {
        "green"
    } else if rate <= 0.35 {
        "yellow"
    } else {
        "red"
    };

    Ok(Json(json!({
        "total_trips": total,
        "cancelled_by_you": cancelled_by_rider,
        "cancellation_rate": rate,
        "level": level,
    })))
}
