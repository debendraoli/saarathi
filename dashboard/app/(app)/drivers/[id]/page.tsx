"use client";

import { Modal } from "@/components/Modal";
import { TopupModal } from "@/components/TopupModal";
import { TripMap } from "@/components/TripMap";
import { api, auth, rides, type DriverAnalytics, type DriverDetail, type DriverDocument, type TripRoute } from "@/lib/api";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { use, useEffect, useState } from "react";

export default function DriverDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  // Both the KYC queue and the general directory link here — send "back"
  // wherever the staff member actually came from instead of always the
  // queue, and keep the sidebar highlighting that same page (see layout.tsx).
  const fromAll = useSearchParams().get("from") === "all";
  const backHref = fromAll ? "/drivers/all" : "/drivers";
  const backLabel = fromAll ? "← Back to drivers" : "← Back to queue";
  const [data, setData] = useState<DriverDetail | null>(null);
  const [analytics, setAnalytics] = useState<DriverAnalytics | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [rejecting, setRejecting] = useState(false);
  const [reason, setReason] = useState("");
  const [showTopup, setShowTopup] = useState(false);
  const canTopup = ["super_admin", "admin"].includes(auth.user?.role ?? "");
  const [routeFor, setRouteFor] = useState<string | null>(null);
  const [route, setRoute] = useState<TripRoute | null>(null);
  const [routeError, setRouteError] = useState<string | null>(null);

  function viewRoute(tripId: string) {
    setRouteFor(tripId);
    setRoute(null);
    setRouteError(null);
    rides
      .tripRoute(tripId)
      .then(setRoute)
      .catch((e) => setRouteError((e as Error).message));
  }

  async function load() {
    setError(null);
    try {
      const d = await api.driverDetail(id);
      setData(d);
      // Best-effort — analytics keys on the user id, not the driver row id.
      rides.driverAnalytics(d.user.id).then(setAnalytics).catch(() => {});
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
        <Link href={backHref} className="muted-link">{backLabel}</Link>
        {error ? <div className="error">{error}</div> : <p className="subtle">Loading…</p>}
      </div>
    );
  }

  const { driver, user, vehicle, documents } = data;
  const decided = driver.kyc_status === "approved" || driver.kyc_status === "rejected";

  return (
    <div className="stack">
      <Link href={backHref} className="muted-link">{backLabel}</Link>

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

      {canTopup && (
        <div className="row">
          <button className="btn primary" onClick={() => setShowTopup(true)}>
            Top up credits
          </button>
        </div>
      )}

      {analytics && (
        <div className="stat-grid">
          <div className="stat">
            <div className="label">Total trips</div>
            <div className="value">{analytics.total_trips}</div>
          </div>
          <div className="stat">
            <div className="label">Completed</div>
            <div className="value">{analytics.completed_trips}</div>
          </div>
          <div className="stat">
            <div className="label">Cancelled</div>
            <div className="value">{analytics.cancelled_trips}</div>
          </div>
          <div className="stat">
            <div className="label">Earnings</div>
            <div className="value">NPR {analytics.total_earnings}</div>
          </div>
          <div className="stat">
            <div className="label">Rating</div>
            <div className="value">
              {analytics.avg_rating != null ? `${analytics.avg_rating.toFixed(1)} ★` : "—"}
            </div>
            {analytics.rating_count > 0 && (
              <div className="subtle" style={{ fontSize: 12.5 }}>{analytics.rating_count} ratings</div>
            )}
          </div>
        </div>
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

      {analytics && analytics.recent_trips.length > 0 && (
        <div className="card" style={{ padding: 0 }}>
          <table>
            <thead>
              <tr>
                <th>Rider</th>
                <th>Status</th>
                <th>Fare</th>
                <th>Pay</th>
                <th>Rating</th>
                <th>When</th>
              </tr>
            </thead>
            <tbody>
              {analytics.recent_trips.map((t) => (
                <tr key={t.id} onClick={() => viewRoute(t.id)}>
                  <td>{t.rider_name ?? t.rider_id.slice(0, 8)}</td>
                  <td>
                    <span className={`badge ${t.status === "completed" ? "approved" : t.status === "cancelled" ? "rejected" : "under_review"}`}>
                      {t.status.replace("_", " ")}
                    </span>
                  </td>
                  <td>NPR {t.final_fare}</td>
                  <td className="subtle">{t.payment_method}</td>
                  <td>{t.driver_stars ? "★".repeat(t.driver_stars) : "—"}</td>
                  <td className="subtle">{new Date(t.created_at).toLocaleString()}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

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

      <TopupModal
        open={showTopup}
        onClose={() => setShowTopup(false)}
        userId={user.id}
        kind="driver"
        onDone={() => load()}
      />

      <Modal open={routeFor !== null} onClose={() => setRouteFor(null)} title="Trip route" wide>
        {routeError && <div className="error">{routeError}</div>}
        {!routeError && !route && <p className="subtle">Loading…</p>}
        {route && (
          <>
            <p className="subtle" style={{ marginTop: 0 }}>
              {route.breadcrumbs.length > 0
                ? `${route.breadcrumbs.length} recorded points · status: ${route.status.replace("_", " ")}`
                : `No location pings recorded for this trip · status: ${route.status.replace("_", " ")}`}
            </p>
            <TripMap
              origin={{ lat: route.origin_lat, lng: route.origin_lng }}
              dest={{ lat: route.dest_lat, lng: route.dest_lng }}
              breadcrumbs={route.breadcrumbs}
              heightPx={480}
            />
          </>
        )}
      </Modal>
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
