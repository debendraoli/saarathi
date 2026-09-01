//! Public-safe partner listing — every signed-in app user (rider/driver/
//! merchant, not just staff), for the app's own "About → Partners" legal-
//! disclosure screen. Deliberately a much narrower projection than
//! `admin::Partner`: no `contact_email`, `commission_share`, or internal
//! `status` — those are operational data, not something a rider needs to
//! see about who operates the fleet they're riding with. Only ever lists
//! `active` partners, same reasoning as not surfacing a suspended/pending
//! one in a disclosure list meant to answer "who runs this".

use crate::auth::AuthUser;
use crate::error::AppResult;
use crate::state::AppState;
use axum::extract::{Query, State};
use axum::{Json, Router, routing::get};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new().route("/v1/partners", get(list))
}

#[derive(Serialize, sqlx::FromRow)]
struct PublicPartner {
    id: Uuid,
    name: String,
    pan_vat: Option<String>,
    city: Option<String>,
    contact_phone: Option<String>,
}

/// Same small per-service pagination helper every other list endpoint this
/// session added has its own copy of (see e.g. `rides::routes::rides`'s
/// `PageQuery`) — not worth a shared crate for a few lines.
#[derive(Deserialize)]
struct PageQuery {
    #[serde(default)]
    limit: Option<i64>,
    #[serde(default)]
    offset: Option<i64>,
}

async fn list(
    State(st): State<AppState>,
    _user: AuthUser,
    Query(page): Query<PageQuery>,
) -> AppResult<Json<Vec<PublicPartner>>> {
    let limit = page.limit.unwrap_or(20).clamp(1, 100);
    let offset = page.offset.unwrap_or(0).max(0);
    let rows: Vec<PublicPartner> = sqlx::query_as(
        "SELECT id, name, pan_vat, city, contact_phone FROM partners \
         WHERE status = 'active' ORDER BY created_at DESC LIMIT $1 OFFSET $2",
    )
    .bind(limit)
    .bind(offset)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}
