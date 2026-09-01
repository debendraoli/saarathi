//! Ops onboarding and the staff merchant-approval review queue.

use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use saarathi_core::api::ErrorCode;
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

#[derive(Deserialize)]
pub(super) struct CreateMerchant {
    name: String,
    vertical: String,
    lat: f64,
    lng: f64,
    address: Option<String>,
    phone: Option<String>,
    /// Ties this store to a merchant-app account the vendor already has.
    /// Left unset for a plain walk-in vendor with no app account yet — the
    /// store stays unowned (`owner_user_id NULL`) rather than defaulting to
    /// the onboarding staff member's own account, which would (a) be wrong
    /// attribution and (b) collide with the one-store-per-owner rule the
    /// moment that staff member onboards a second walk-in.
    owner_user_id: Option<Uuid>,
    prep_mins: Option<i32>,
}

pub(super) async fn create_merchant(
    State(st): State<AppState>,
    crate::auth::StaffUser(claims): crate::auth::StaffUser,
    Json(body): Json<CreateMerchant>,
) -> AppResult<Json<Value>> {
    if !matches!(body.vertical.as_str(), "food" | "grocery") {
        return Err(AppError::BadRequest(
            "vertical must be 'food' or 'grocery'".into(),
        ));
    }
    let owner = body.owner_user_id;
    // One store per registration, same rule as self-service apply — only
    // applies when an owner was actually specified; unowned walk-ins are
    // exempt since they don't hold anyone's one-store slot.
    if let Some(owner) = owner {
        let existing: Option<Uuid> = sqlx::query_scalar(
            "SELECT id FROM merchants WHERE owner_user_id = $1 AND status <> 'rejected'",
        )
        .bind(owner)
        .fetch_optional(&st.db)
        .await?;
        if existing.is_some() {
            return Err(AppError::Coded(
                StatusCode::CONFLICT,
                ErrorCode::Conflict,
                "this owner already has a registered store".into(),
            ));
        }
    }
    // Staff-onboarded (on-site) stores skip the review queue entirely — a
    // staff member creating this directly has already vetted it in person,
    // same reasoning as drivers' `onboarded_by` walk-in KYC path.
    let id: Uuid = sqlx::query_scalar(
        "INSERT INTO merchants \
             (owner_user_id, name, vertical, address, phone, lat, lng, prep_mins, \
              status, approved_at, reviewed_by, reviewed_at) \
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,'approved',now(),$9,now()) RETURNING id",
    )
    .bind(owner)
    .bind(body.name.trim())
    .bind(&body.vertical)
    .bind(body.address)
    .bind(body.phone)
    .bind(body.lat)
    .bind(body.lng)
    .bind(body.prep_mins.unwrap_or(20))
    .bind(claims.sub)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({ "id": id, "owner_user_id": owner })))
}

// ── Staff review queue ──────────────────────────────────────────────────────

#[derive(Deserialize)]
pub(super) struct MerchantQueueQuery {
    #[serde(default)]
    status: Option<String>,
}

/// Pending applications by default (`?status=all` for every store, any
/// state) — the review queue's landing view.
pub(super) async fn merchant_queue(
    State(st): State<AppState>,
    crate::auth::StaffUser(_claims): crate::auth::StaffUser,
    Query(q): Query<MerchantQueueQuery>,
) -> AppResult<Json<Vec<super::merchants::Merchant>>> {
    let all = q.status.as_deref() == Some("all");
    let rows: Vec<super::merchants::Merchant> = sqlx::query_as(
        "SELECT id, name, vertical, address, phone, lat, lng, prep_mins, is_open, rating, image_key, \
                status::text, rejection_reason, \
                0::double precision AS distance_m \
         FROM merchants WHERE $1 OR status = 'pending' ORDER BY created_at",
    )
    .bind(all)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

pub(super) async fn approve_merchant(
    State(st): State<AppState>,
    crate::auth::StaffUser(claims): crate::auth::StaffUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    if !claims.can_approve() {
        return Err(AppError::Forbidden);
    }
    // Guarded on the current status so two staff acting on the same
    // application at once can't clobber each other — the loser's WHERE
    // matches nothing (same pattern as driver KYC approval).
    let updated: Option<(Option<Uuid>, String, String, f64, f64)> = sqlx::query_as(
        "UPDATE merchants SET status = 'approved', approved_at = now(), reviewed_at = now(), \
         reviewed_by = $2, rejection_reason = NULL \
         WHERE id = $1 AND status = 'pending' \
         RETURNING owner_user_id, name, vertical, lat, lng",
    )
    .bind(id)
    .bind(claims.sub)
    .fetch_optional(&st.db)
    .await?;
    let Some((owner, name, vertical, lat, lng)) = updated else {
        return Err(AppError::Coded(
            StatusCode::CONFLICT,
            ErrorCode::Conflict,
            "store has already been reviewed".into(),
        ));
    };

    // Findable via address search immediately, same as an approved
    // place-contribution — best-effort, never blocks approval on a Pelias
    // hiccup (see saarathi_core::pelias_index's own doc comment).
    saarathi_core::pelias_index::index_place(
        &st.config.pelias_es_url,
        id,
        &vertical,
        &name,
        lat,
        lng,
    )
    .await;

    if let Some(owner) = owner {
        crate::notify::send(
            &st.nats,
            owner,
            saarathi_core::domain::notif::TRANSACTIONAL,
            "Store approved",
            "Your store is approved — you can open it and start taking orders.",
            Some("saarathi://merchant/dashboard".to_string()),
        )
        .await;
    }
    Ok(Json(json!({ "ok": true })))
}

#[derive(Deserialize)]
pub(super) struct UpdateMerchant {
    name: Option<String>,
    address: Option<String>,
    phone: Option<String>,
    prep_mins: Option<i32>,
    vertical: Option<String>,
}

/// Staff correction of a listing's own details — typo fixes, not the
/// approve/reject decision or the owner's own open/closed toggle.
pub(super) async fn update_merchant(
    State(st): State<AppState>,
    crate::auth::StaffUser(claims): crate::auth::StaffUser,
    Path(id): Path<Uuid>,
    Json(body): Json<UpdateMerchant>,
) -> AppResult<Json<Value>> {
    if !claims.can_approve() {
        return Err(AppError::Forbidden);
    }
    if let Some(name) = &body.name
        && name.trim().is_empty()
    {
        return Err(AppError::BadRequest("name cannot be empty".into()));
    }
    if let Some(address) = &body.address
        && address.trim().is_empty()
    {
        return Err(AppError::BadRequest("address cannot be empty".into()));
    }
    if let Some(vertical) = &body.vertical
        && !matches!(vertical.as_str(), "food" | "grocery")
    {
        return Err(AppError::BadRequest(
            "vertical must be 'food' or 'grocery'".into(),
        ));
    }

    let name = body.name.as_deref().map(str::trim);
    let updated: Option<(Uuid,)> = sqlx::query_as(
        "UPDATE merchants SET \
             name = COALESCE($2, name), \
             address = COALESCE($3, address), \
             phone = COALESCE($4, phone), \
             prep_mins = COALESCE($5, prep_mins), \
             vertical = COALESCE($6, vertical) \
         WHERE id = $1 RETURNING id",
    )
    .bind(id)
    .bind(name)
    .bind(&body.address)
    .bind(&body.phone)
    .bind(body.prep_mins)
    .bind(&body.vertical)
    .fetch_optional(&st.db)
    .await?;
    updated.ok_or(AppError::NotFound)?;

    saarathi_core::audit::record(
        &st.db,
        claims.sub,
        "merchant.update",
        "merchant",
        id,
        json!({
            "name": name,
            "address": body.address,
            "phone": body.phone,
            "prep_mins": body.prep_mins,
            "vertical": body.vertical,
        }),
    )
    .await?;

    Ok(Json(json!({ "ok": true })))
}

#[derive(Deserialize)]
pub(super) struct RejectMerchant {
    reason: String,
}

pub(super) async fn reject_merchant(
    State(st): State<AppState>,
    crate::auth::StaffUser(claims): crate::auth::StaffUser,
    Path(id): Path<Uuid>,
    Json(body): Json<RejectMerchant>,
) -> AppResult<Json<Value>> {
    if !claims.can_approve() {
        return Err(AppError::Forbidden);
    }
    if body.reason.trim().is_empty() {
        return Err(AppError::BadRequest(
            "a rejection reason is required".into(),
        ));
    }
    let updated: Option<(Option<Uuid>,)> = sqlx::query_as(
        "UPDATE merchants SET status = 'rejected', reviewed_at = now(), reviewed_by = $2, \
         rejection_reason = $3, approved_at = NULL \
         WHERE id = $1 AND status = 'pending' RETURNING owner_user_id",
    )
    .bind(id)
    .bind(claims.sub)
    .bind(&body.reason)
    .fetch_optional(&st.db)
    .await?;
    let Some((owner,)) = updated else {
        return Err(AppError::Coded(
            StatusCode::CONFLICT,
            ErrorCode::Conflict,
            "store has already been reviewed".into(),
        ));
    };
    if let Some(owner) = owner {
        crate::notify::send(
            &st.nats,
            owner,
            saarathi_core::domain::notif::TRANSACTIONAL,
            "Store application rejected",
            &format!("Your store application was rejected: {}", body.reason),
            None,
        )
        .await;
    }
    Ok(Json(json!({ "ok": true })))
}
