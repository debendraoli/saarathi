//! Saved payout destinations (bank account or e-wallet). A user can have many,
//! but exactly one is the default — the DB enforces "at most one" (partial
//! unique index on `is_default`); "at least one once any exist" is handled
//! here: the first account created is forced default, and deleting the
//! default promotes the next-most-recent remaining account.

use crate::auth::AuthUser;
use crate::error::{AppError, AppResult};
use crate::state::AppState;
use axum::extract::{Path, State};
use axum::{
    routing::{get, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use saarathi_core::api::ErrorCode;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/payout-accounts", get(list).post(create))
        .route("/v1/payout-accounts/{id}", axum::routing::delete(remove))
        .route("/v1/payout-accounts/{id}/default", post(set_default))
}

#[derive(Serialize, sqlx::FromRow)]
struct PayoutAccount {
    id: Uuid,
    kind: String,
    label: String,
    details: Value,
    is_default: bool,
    created_at: DateTime<Utc>,
}

async fn list(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
) -> AppResult<Json<Vec<PayoutAccount>>> {
    let rows: Vec<PayoutAccount> = sqlx::query_as(
        "SELECT id, kind, label, details, is_default, created_at \
         FROM payout_accounts WHERE user_id = $1 ORDER BY is_default DESC, created_at DESC",
    )
    .bind(claims.sub)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

#[derive(Deserialize)]
struct CreateAccount {
    kind: String,
    label: String,
    details: Value,
    #[serde(default)]
    make_default: bool,
}

async fn create(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Json(body): Json<CreateAccount>,
) -> AppResult<Json<PayoutAccount>> {
    if !matches!(body.kind.as_str(), "bank" | "wallet") {
        return Err(AppError::bad(
            ErrorCode::Validation,
            "kind must be 'bank' or 'wallet'",
        ));
    }
    if body.label.trim().is_empty() {
        return Err(AppError::bad(ErrorCode::Validation, "label is required"));
    }

    let mut tx = st.db.begin().await?;
    let (existing_count,): (i64,) =
        sqlx::query_as("SELECT count(*) FROM payout_accounts WHERE user_id = $1")
            .bind(claims.sub)
            .fetch_one(&mut *tx)
            .await?;
    // The first account is always the default; otherwise honour the request.
    let make_default = existing_count == 0 || body.make_default;
    if make_default {
        sqlx::query("UPDATE payout_accounts SET is_default = false WHERE user_id = $1")
            .bind(claims.sub)
            .execute(&mut *tx)
            .await?;
    }
    let row: PayoutAccount = sqlx::query_as(
        "INSERT INTO payout_accounts (user_id, kind, label, details, is_default) \
         VALUES ($1, $2, $3, $4, $5) \
         RETURNING id, kind, label, details, is_default, created_at",
    )
    .bind(claims.sub)
    .bind(&body.kind)
    .bind(&body.label)
    .bind(&body.details)
    .bind(make_default)
    .fetch_one(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Json(row))
}

async fn set_default(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let mut tx = st.db.begin().await?;
    let owned: Option<(Uuid,)> =
        sqlx::query_as("SELECT id FROM payout_accounts WHERE id = $1 AND user_id = $2 FOR UPDATE")
            .bind(id)
            .bind(claims.sub)
            .fetch_optional(&mut *tx)
            .await?;
    owned.ok_or(AppError::NotFound)?;
    sqlx::query("UPDATE payout_accounts SET is_default = false WHERE user_id = $1")
        .bind(claims.sub)
        .execute(&mut *tx)
        .await?;
    sqlx::query("UPDATE payout_accounts SET is_default = true WHERE id = $1")
        .bind(id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(Json(serde_json::json!({ "ok": true, "default": id })))
}

async fn remove(
    State(st): State<AppState>,
    AuthUser(claims): AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let mut tx = st.db.begin().await?;
    let row: Option<(bool,)> = sqlx::query_as(
        "DELETE FROM payout_accounts WHERE id = $1 AND user_id = $2 RETURNING is_default",
    )
    .bind(id)
    .bind(claims.sub)
    .fetch_optional(&mut *tx)
    .await?;
    let (was_default,) = row.ok_or(AppError::NotFound)?;
    if was_default {
        // Promote the next-most-recent remaining account, if any.
        sqlx::query(
            "UPDATE payout_accounts SET is_default = true WHERE id = ( \
                SELECT id FROM payout_accounts WHERE user_id = $1 \
                ORDER BY created_at DESC LIMIT 1 \
             )",
        )
        .bind(claims.sub)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    Ok(Json(serde_json::json!({ "ok": true })))
}
