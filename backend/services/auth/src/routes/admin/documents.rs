//! Driver KYC document upload/viewing.

use crate::audit;
use crate::error::{AppError, AppResult};
use crate::models::{DocumentKind, DriverDocument};
use crate::state::{AppState, StaffUser};
use axum::extract::{Multipart, Path, State};
use axum::http::header;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;
use uuid::Uuid;

/// Staff uploads a KYC document on a walk-in driver's behalf.
pub(super) async fn upload_driver_document(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Path(driver_id): Path<Uuid>,
    mut multipart: Multipart,
) -> AppResult<Json<DriverDocument>> {
    if !claims.can_review_kyc() {
        return Err(AppError::Forbidden);
    }
    // Confirm the driver exists.
    let exists: Option<(Uuid,)> = sqlx::query_as("SELECT id FROM drivers WHERE id = $1")
        .bind(driver_id)
        .fetch_optional(&st.db)
        .await?;
    if exists.is_none() {
        return Err(AppError::NotFound);
    }

    let mut kind: Option<DocumentKind> = None;
    let mut content_type: Option<String> = None;
    let mut bytes: Option<Vec<u8>> = None;
    while let Some(field) = multipart
        .next_field()
        .await
        .map_err(|e| AppError::BadRequest(e.to_string()))?
    {
        match field.name() {
            Some("kind") => {
                let text = field
                    .text()
                    .await
                    .map_err(|e| AppError::BadRequest(e.to_string()))?;
                kind = Some(parse_document_kind(&text)?);
            }
            Some("file") => {
                content_type = field.content_type().map(|s| s.to_string());
                let data = field
                    .bytes()
                    .await
                    .map_err(|e| AppError::BadRequest(e.to_string()))?;
                bytes = Some(data.to_vec());
            }
            _ => {}
        }
    }
    let kind = kind.ok_or_else(|| AppError::BadRequest("missing 'kind' field".into()))?;
    let bytes = bytes.ok_or_else(|| AppError::BadRequest("missing 'file' field".into()))?;
    if bytes.is_empty() {
        return Err(AppError::BadRequest("empty file".into()));
    }

    let storage_key = format!("{driver_id}/{}", Uuid::new_v4());
    st.docs
        .put(&storage_key, bytes)
        .await
        .map_err(AppError::Other)?;

    let doc: DriverDocument = sqlx::query_as(
        "INSERT INTO driver_documents (driver_id, kind, storage_key, content_type, status) \
         VALUES ($1, $2, $3, $4, 'submitted') \
         RETURNING id, driver_id, kind, storage_key, content_type, status, expires_at, rejection_reason, created_at",
    )
    .bind(driver_id)
    .bind(kind)
    .bind(&storage_key)
    .bind(content_type)
    .fetch_one(&st.db)
    .await?;

    audit::record(
        &st.db,
        claims.sub,
        "driver.document.upload",
        "driver",
        driver_id,
        json!({}),
    )
    .await?;
    Ok(Json(doc))
}

fn parse_document_kind(s: &str) -> Result<DocumentKind, AppError> {
    Ok(match s {
        "citizenship" => DocumentKind::Citizenship,
        "citizenship_front" => DocumentKind::CitizenshipFront,
        "citizenship_back" => DocumentKind::CitizenshipBack,
        "license" => DocumentKind::License,
        "bluebook" => DocumentKind::Bluebook,
        "vehicle_fitness" => DocumentKind::VehicleFitness,
        "insurance" => DocumentKind::Insurance,
        "tax_clearance" => DocumentKind::TaxClearance,
        "profile_photo" => DocumentKind::ProfilePhoto,
        "vehicle_photo" => DocumentKind::VehiclePhoto,
        other => {
            return Err(AppError::bad(
                saarathi_core::api::ErrorCode::DocumentInvalid,
                format!("unknown document kind '{other}'"),
            ));
        }
    })
}

pub(super) async fn document_content(
    State(st): State<AppState>,
    StaffUser(claims): StaffUser,
    Path(id): Path<Uuid>,
) -> AppResult<Response> {
    let row: Option<(String, Option<String>)> =
        sqlx::query_as("SELECT storage_key, content_type FROM driver_documents WHERE id = $1")
            .bind(id)
            .fetch_optional(&st.db)
            .await?;
    let (storage_key, content_type) = row.ok_or(AppError::NotFound)?;

    let bytes = st
        .docs
        .get(&storage_key)
        .await
        .map_err(|_| AppError::NotFound)?;
    audit::record(
        &st.db,
        claims.sub,
        "document.view",
        "driver_document",
        id,
        json!({}),
    )
    .await?;

    let ct = content_type.unwrap_or_else(|| "application/octet-stream".into());
    Ok(([(header::CONTENT_TYPE, ct)], bytes).into_response())
}
