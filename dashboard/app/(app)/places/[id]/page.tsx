"use client";

import { TripMap } from "@/components/TripMap";
import { places, type PlaceContributionAdmin } from "@/lib/api";
import Link from "next/link";
import { use, useEffect, useState } from "react";

export default function PlaceDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const [data, setData] = useState<PlaceContributionAdmin | null>(null);
  const [photoUrl, setPhotoUrl] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [rejecting, setRejecting] = useState(false);
  const [reason, setReason] = useState("");

  async function load() {
    setError(null);
    try {
      const d = await places.detail(id);
      setData(d);
    } catch (e) {
      setError((e as Error).message);
    }
  }

  useEffect(() => {
    load();
    places
      .photoBlobUrl(id)
      .then(setPhotoUrl)
      .catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  async function approve() {
    setBusy(true);
    setError(null);
    try {
      await places.approve(id);
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function reject() {
    if (!reason.trim()) {
      setError("A rejection reason is required.");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await places.reject(id, reason.trim());
      setRejecting(false);
      setReason("");
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  if (!data) {
    return (
      <div className="stack">
        <Link href="/places" className="muted-link">← Back to queue</Link>
        {error ? <div className="error">{error}</div> : <p className="subtle">Loading…</p>}
      </div>
    );
  }

  const decided = data.status === "approved" || data.status === "rejected";

  return (
    <div className="stack">
      <Link href="/places" className="muted-link">← Back to queue</Link>

      <div className="row">
        <h1 className="page-title" style={{ margin: 0 }}>{data.name}</h1>
        <span className={`badge ${data.status}`}>{data.status}</span>
      </div>

      {error && <div className="error">{error}</div>}
      {data.status === "rejected" && data.rejection_reason && (
        <div className="error">Rejected: {data.rejection_reason}</div>
      )}

      <div className="grid-2">
        <div className="card">
          <h3 style={{ marginTop: 0 }}>Submission</h3>
          <dl className="kv">
            <dt>Category</dt>
            <dd>{data.category.replace("_", " ")}</dd>
            <dt>Description</dt>
            <dd>{data.description ?? "—"}</dd>
            <dt>Capture distance</dt>
            <dd>{Math.round(data.capture_distance_m)} m from the pinned location</dd>
            <dt>Points awarded</dt>
            <dd>{data.points_awarded ?? "—"}</dd>
            <dt>Submitted</dt>
            <dd>{new Date(data.created_at).toLocaleString()}</dd>
          </dl>
        </div>

        <div className="card">
          <h3 style={{ marginTop: 0 }}>Proof photo</h3>
          {photoUrl ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img
              src={photoUrl}
              alt="Proof"
              style={{ width: "100%", borderRadius: 12, objectFit: "cover" }}
            />
          ) : (
            <p className="subtle">Loading photo…</p>
          )}
        </div>
      </div>

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Claimed pin vs. capture location</h3>
        <p className="subtle" style={{ marginTop: -8 }}>
          Green = the pinned location being contributed. Red = where the device actually was when
          the photo was taken.
        </p>
        <TripMap
          origin={{ lat: data.lat, lng: data.lng }}
          dest={{ lat: data.capture_lat, lng: data.capture_lng }}
          heightPx={320}
        />
      </div>

      {!decided && (
        <div className="card">
          <h3 style={{ marginTop: 0 }}>Decision</h3>
          {rejecting ? (
            <>
              <div className="field">
                <label>Rejection reason (shown to the contributor)</label>
                <input
                  className="input"
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  placeholder="e.g. Photo doesn't clearly show the place"
                />
              </div>
              <div className="row">
                <button className="btn danger" disabled={busy} onClick={reject}>
                  Confirm rejection
                </button>
                <button className="btn ghost" onClick={() => setRejecting(false)}>
                  Cancel
                </button>
              </div>
            </>
          ) : (
            <div className="row">
              <button className="btn primary" disabled={busy} onClick={approve}>
                Approve
              </button>
              <button className="btn danger" disabled={busy} onClick={() => setRejecting(true)}>
                Reject
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
