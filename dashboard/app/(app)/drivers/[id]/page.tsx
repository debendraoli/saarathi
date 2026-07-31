"use client";

import { api, type DriverDetail, type DriverDocument } from "@/lib/api";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { use, useEffect, useState } from "react";

export default function DriverDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const router = useRouter();
  const [data, setData] = useState<DriverDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [rejecting, setRejecting] = useState(false);
  const [reason, setReason] = useState("");

  async function load() {
    setError(null);
    try {
      setData(await api.driverDetail(id));
    } catch (e) {
      setError((e as Error).message);
    }
  }

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  async function approve() {
    setBusy(true);
    setError(null);
    try {
      await api.approveDriver(id);
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
      await api.rejectDriver(id, reason.trim());
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
        <Link href="/drivers" className="muted-link">← Back to queue</Link>
        {error ? <div className="error">{error}</div> : <p className="subtle">Loading…</p>}
      </div>
    );
  }

  const { driver, user, vehicle, documents } = data;
  const decided = driver.kyc_status === "approved" || driver.kyc_status === "rejected";

  return (
    <div className="stack">
      <Link href="/drivers" className="muted-link">← Back to queue</Link>

      <div className="row">
        <h1 className="page-title" style={{ margin: 0 }}>
          {user.full_name ?? user.phone}
        </h1>
        <span className={`badge ${driver.kyc_status}`}>{driver.kyc_status.replace("_", " ")}</span>
      </div>

      {error && <div className="error">{error}</div>}
      {driver.kyc_status === "rejected" && driver.rejection_reason && (
        <div className="error">Rejected: {driver.rejection_reason}</div>
      )}

      <div className="grid-2">
        <div className="card">
          <h3 style={{ marginTop: 0 }}>Applicant</h3>
          <dl className="kv">
            <dt>Phone</dt>
            <dd>{user.phone}</dd>
            <dt>Full name</dt>
            <dd>{user.full_name ?? "—"}</dd>
            <dt>License #</dt>
            <dd>{driver.license_number ?? "—"}</dd>
            <dt>Date of birth</dt>
            <dd>{driver.date_of_birth ?? "—"}</dd>
            <dt>Address</dt>
            <dd>{driver.address ?? "—"}</dd>
          </dl>
        </div>

        <div className="card">
          <h3 style={{ marginTop: 0 }}>Vehicle</h3>
          {vehicle ? (
            <dl className="kv">
              <dt>Class</dt>
              <dd>{vehicle.class.replace("_", " ")}</dd>
              <dt>Plate</dt>
              <dd>{vehicle.plate_number}</dd>
              <dt>Make / Model</dt>
              <dd>{[vehicle.make, vehicle.model].filter(Boolean).join(" ") || "—"}</dd>
              <dt>Year</dt>
              <dd>{vehicle.year ?? "—"}</dd>
              <dt>Colour</dt>
              <dd>{vehicle.color ?? "—"}</dd>
            </dl>
          ) : (
            <p className="subtle">No vehicle on file.</p>
          )}
        </div>
      </div>

      <div className="card">
        <h3 style={{ marginTop: 0 }}>KYC documents</h3>
        {documents.length === 0 ? (
          <p className="subtle">No documents submitted.</p>
        ) : (
          <div className="doc-list">
            {documents.map((doc) => (
              <DocRow key={doc.id} doc={doc} />
            ))}
          </div>
        )}
      </div>

      {!decided && (
        <div className="card">
          <h3 style={{ marginTop: 0 }}>Decision</h3>
          {rejecting ? (
            <>
              <div className="field">
                <label>Rejection reason (shown to the driver)</label>
                <input
                  className="input"
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  placeholder="e.g. License photo is unreadable"
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
                Approve driver
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

function DocRow({ doc }: { doc: DriverDocument }) {
  const [loading, setLoading] = useState(false);

  async function view() {
    setLoading(true);
    try {
      const url = await api.documentBlobUrl(doc.id);
      window.open(url, "_blank");
    } catch (e) {
      alert((e as Error).message);
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="doc-row">
      <div>
        <b>{doc.kind.replace("_", " ")}</b>
        <div className="subtle" style={{ fontSize: 13 }}>
          {doc.content_type ?? "file"} · {new Date(doc.created_at).toLocaleDateString()}
        </div>
      </div>
      <div className="row">
        <span className={`badge ${doc.status}`}>{doc.status}</span>
        <button className="btn ghost" disabled={loading} onClick={view}>
          {loading ? "Opening…" : "View"}
        </button>
      </div>
    </div>
  );
}
