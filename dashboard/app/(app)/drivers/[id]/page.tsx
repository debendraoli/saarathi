"use client";

import { ConfirmModal, Modal } from "@/components/Modal";
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
  const [showSuspend, setShowSuspend] = useState(false);
  const [statusBusy, setStatusBusy] = useState(false);
  const [serviceTypesDraft, setServiceTypesDraft] = useState<string[]>([]);
  const [serviceTypesBusy, setServiceTypesBusy] = useState(false);
  const [detailsDraft, setDetailsDraft] = useState({
    full_name: "",
    license_number: "",
    date_of_birth: "",
    address: "",
    make: "",
    model: "",
    year: "",
    plate_number: "",
    color: "",
  });
  const [detailsBusy, setDetailsBusy] = useState(false);
  const [detailsDirty, setDetailsDirty] = useState(false);
  const isAdmin = ["super_admin", "admin"].includes(auth.user?.role ?? "");
  const canTopup = isAdmin;
  const [routeFor, setRouteFor] = useState<string | null>(null);
  const [route, setRoute] = useState<TripRoute | null>(null);
  const [routeError, setRouteError] = useState<string | null>(null);

  async function suspend() {
    setStatusBusy(true);
    setError(null);
    try {
      await api.suspendDriver(id);
      setShowSuspend(false);
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setStatusBusy(false);
    }
  }

  async function reactivate() {
    setStatusBusy(true);
    setError(null);
    try {
      await api.reactivateDriver(id);
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setStatusBusy(false);
    }
  }

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
      setServiceTypesDraft(d.driver.service_types);
      setDetailsDraft({
        full_name: d.user.full_name ?? "",
        license_number: d.driver.license_number ?? "",
        date_of_birth: d.driver.date_of_birth ?? "",
        address: d.driver.address ?? "",
        make: d.vehicle?.make ?? "",
        model: d.vehicle?.model ?? "",
        year: d.vehicle?.year != null ? String(d.vehicle.year) : "",
        plate_number: d.vehicle?.plate_number ?? "",
        color: d.vehicle?.color ?? "",
      });
      setDetailsDirty(false);
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

  function setDetailField<K extends keyof typeof detailsDraft>(key: K, value: string) {
    setDetailsDraft((cur) => ({ ...cur, [key]: value }));
    setDetailsDirty(true);
  }

  async function saveDetails() {
    setDetailsBusy(true);
    setError(null);
    try {
      const year = detailsDraft.year.trim();
      await api.updateDriver(id, {
        full_name: detailsDraft.full_name.trim(),
        license_number: detailsDraft.license_number.trim(),
        date_of_birth: detailsDraft.date_of_birth.trim() || undefined,
        address: detailsDraft.address.trim(),
        ...(data?.vehicle
          ? {
              vehicle: {
                make: detailsDraft.make.trim(),
                model: detailsDraft.model.trim(),
                year: year ? Number(year) : undefined,
                plate_number: detailsDraft.plate_number.trim(),
                color: detailsDraft.color.trim(),
              },
            }
          : {}),
      });
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setDetailsBusy(false);
    }
  }

  function toggleServiceType(type: string) {
    setServiceTypesDraft((cur) =>
      cur.includes(type) ? cur.filter((t) => t !== type) : [...cur, type],
    );
  }

  async function saveServiceTypes() {
    if (serviceTypesDraft.length === 0) {
      setError("Select at least one job type.");
      return;
    }
    setServiceTypesBusy(true);
    setError(null);
    try {
      await api.updateDriverServiceTypes(id, serviceTypesDraft);
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setServiceTypesBusy(false);
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
        {user.status !== "active" && (
          <span className="badge rejected">{user.status}</span>
        )}
      </div>

      {error && <div className="error">{error}</div>}
      {driver.kyc_status === "rejected" && driver.rejection_reason && (
        <div className="error">Rejected: {driver.rejection_reason}</div>
      )}

      <div className="row">
        {canTopup && (
          <button className="btn primary" onClick={() => setShowTopup(true)}>
            Top up credits
          </button>
        )}
        {isAdmin &&
          (user.status === "suspended" ? (
            <button className="btn ghost" disabled={statusBusy} onClick={reactivate}>
              {statusBusy ? "Working…" : "Reactivate"}
            </button>
          ) : (
            <button className="btn danger" disabled={statusBusy} onClick={() => setShowSuspend(true)}>
              Suspend
            </button>
          ))}
      </div>

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
          </dl>
          <div className="stack" style={{ gap: 10, marginTop: 10 }}>
            <div className="field">
              <label>Full name</label>
              <input
                className="input"
                value={detailsDraft.full_name}
                onChange={(e) => setDetailField("full_name", e.target.value)}
              />
            </div>
            <div className="field">
              <label>License #</label>
              <input
                className="input"
                value={detailsDraft.license_number}
                onChange={(e) => setDetailField("license_number", e.target.value)}
              />
            </div>
            <div className="field">
              <label>Date of birth</label>
              <input
                className="input"
                type="date"
                value={detailsDraft.date_of_birth}
                onChange={(e) => setDetailField("date_of_birth", e.target.value)}
              />
            </div>
            <div className="field">
              <label>Address</label>
              <input
                className="input"
                value={detailsDraft.address}
                onChange={(e) => setDetailField("address", e.target.value)}
              />
            </div>
          </div>

          <h4 style={{ marginBottom: 8 }}>Job types</h4>
          <div className="row">
            {["ride", "delivery"].map((type) => (
              <label key={type} className="row" style={{ gap: 6 }}>
                <input
                  type="checkbox"
                  checked={serviceTypesDraft.includes(type)}
                  onChange={() => toggleServiceType(type)}
                />
                {type === "ride" ? "Rides" : "Delivery"}
              </label>
            ))}
            <button
              className="btn ghost"
              disabled={
                serviceTypesBusy ||
                JSON.stringify([...serviceTypesDraft].sort()) ===
                  JSON.stringify([...driver.service_types].sort())
              }
              onClick={saveServiceTypes}
            >
              {serviceTypesBusy ? "Saving…" : "Save"}
            </button>
          </div>
        </div>

        <div className="card">
          <h3 style={{ marginTop: 0 }}>Vehicle</h3>
          {vehicle ? (
            <>
              <dl className="kv">
                <dt>Class</dt>
                <dd>{vehicle.class.replace("_", " ")}</dd>
              </dl>
              <div className="stack" style={{ gap: 10, marginTop: 10 }}>
                <div className="field">
                  <label>Plate</label>
                  <input
                    className="input"
                    value={detailsDraft.plate_number}
                    onChange={(e) => setDetailField("plate_number", e.target.value)}
                  />
                </div>
                <div className="field">
                  <label>Make</label>
                  <input
                    className="input"
                    value={detailsDraft.make}
                    onChange={(e) => setDetailField("make", e.target.value)}
                  />
                </div>
                <div className="field">
                  <label>Model</label>
                  <input
                    className="input"
                    value={detailsDraft.model}
                    onChange={(e) => setDetailField("model", e.target.value)}
                  />
                </div>
                <div className="field">
                  <label>Year</label>
                  <input
                    className="input"
                    type="number"
                    value={detailsDraft.year}
                    onChange={(e) => setDetailField("year", e.target.value)}
                  />
                </div>
                <div className="field">
                  <label>Colour</label>
                  <input
                    className="input"
                    value={detailsDraft.color}
                    onChange={(e) => setDetailField("color", e.target.value)}
                  />
                </div>
              </div>
            </>
          ) : (
            <p className="subtle">No vehicle on file.</p>
          )}
        </div>
      </div>

      <div className="form-actions">
        <button
          className="btn primary"
          disabled={
            detailsBusy ||
            !detailsDirty ||
            !detailsDraft.full_name.trim() ||
            !detailsDraft.license_number.trim() ||
            !detailsDraft.address.trim() ||
            (!!vehicle && (!detailsDraft.plate_number.trim() || !detailsDraft.model.trim()))
          }
          onClick={saveDetails}
        >
          {detailsBusy ? "Saving…" : "Save applicant / vehicle details"}
        </button>
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

      <ConfirmModal
        open={showSuspend}
        onClose={() => setShowSuspend(false)}
        onConfirm={suspend}
        title="Suspend this driver?"
        message={`${user.full_name ?? user.phone} will no longer be able to sign in or go online. This doesn't change their KYC status, and doesn't affect any trip already in progress.`}
        confirmLabel="Suspend"
        danger
        busy={statusBusy}
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
