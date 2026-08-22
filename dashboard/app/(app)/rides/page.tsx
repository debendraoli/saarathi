"use client";

import { Modal } from "@/components/Modal";
import { Pagination, SearchInput, usePaged } from "@/components/Toolbar";
import { TripMap } from "@/components/TripMap";
import { rides, type RideRow, type TripRoute } from "@/lib/api";
import { useEffect, useMemo, useState } from "react";

const TABS = ["all", "requested", "accepted", "in_progress", "completed", "cancelled"];

export default function RidesPage() {
  const [status, setStatus] = useState("all");
  const [rows, setRows] = useState<RideRow[]>([]);
  const [query, setQuery] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [routeFor, setRouteFor] = useState<string | null>(null);
  const [route, setRoute] = useState<TripRoute | null>(null);
  const [routeError, setRouteError] = useState<string | null>(null);

  function viewRoute(id: string) {
    setRouteFor(id);
    setRoute(null);
    setRouteError(null);
    rides
      .tripRoute(id)
      .then(setRoute)
      .catch((e) => setRouteError((e as Error).message));
  }

  useEffect(() => {
    let active = true;
    setError(null);
    rides
      .adminRides(status === "all" ? undefined : status)
      .then((r) => active && setRows(r))
      .catch((e) => active && setError((e as Error).message));
    return () => {
      active = false;
    };
  }, [status]);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter((r) => [r.rider_name, r.driver_name].filter(Boolean).some((v) => v!.toLowerCase().includes(q)));
  }, [rows, query]);

  const { page, setPage, pageCount, total, slice } = usePaged(filtered, 15);

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Rides History</h1>
        <p className="subtle">Every ride with status, rating, payment, and cancellation detail.</p>
      </div>

      <div className="toolbar">
        <div className="row">
          {TABS.map((t) => (
            <button
              key={t}
              className={`btn ${status === t ? "primary" : "ghost"}`}
              onClick={() => {
                setStatus(t);
                setPage(0);
              }}
            >
              {t.replace("_", " ")}
            </button>
          ))}
        </div>
        <div className="toolbar-actions">
          <SearchInput value={query} onChange={setQuery} placeholder="Rider or driver name…" />
        </div>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Rider</th>
              <th>Driver</th>
              <th>Status</th>
              <th>Fare</th>
              <th>Pay</th>
              <th>Rating</th>
              <th>Duration</th>
              <th>Cancellation</th>
              <th>When</th>
            </tr>
          </thead>
          <tbody>
            {slice.map((r) => (
              <tr key={r.id} onClick={() => viewRoute(r.id)}>
                <td>{r.rider_name ?? r.rider_id.slice(0, 8)}</td>
                <td>{r.driver_name ?? (r.driver_id ? r.driver_id.slice(0, 8) : "—")}</td>
                <td>
                  <span className={`badge ${badge(r.status)}`}>{r.status.replace("_", " ")}</span>
                </td>
                <td>NPR {r.final_fare}</td>
                <td className="subtle">{r.payment_method}</td>
                <td>{r.driver_stars ? `${"★".repeat(r.driver_stars)}` : "—"}</td>
                <td className="subtle">{fmtDuration(r)}</td>
                <td className="subtle">
                  {r.cancel_reason ? `${r.cancelled_by_role}: ${r.cancel_reason}` : "—"}
                </td>
                <td className="subtle">{new Date(r.created_at).toLocaleString()}</td>
              </tr>
            ))}
            {!error && filtered.length === 0 && (
              <tr><td colSpan={9} className="subtle" style={{ textAlign: "center", padding: 24 }}>No rides.</td></tr>
            )}
          </tbody>
        </table>
      </div>

      <Pagination page={page} pageCount={pageCount} total={total} onPage={setPage} />

      <Modal
        open={routeFor !== null}
        onClose={() => setRouteFor(null)}
        title="Trip route"
        wide
      >
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

// From driver acceptance to completion — the actual ride, not the wait for a
// match. Falls back to request-to-completion if acceptance wasn't recorded.
function fmtDuration(r: RideRow): string {
  if (!r.completed_at) return "—";
  const start = r.accepted_at ?? r.created_at;
  const mins = Math.round((new Date(r.completed_at).getTime() - new Date(start).getTime()) / 60000);
  if (mins < 1) return "<1 min";
  if (mins < 60) return `${mins} min`;
  return `${Math.floor(mins / 60)}h ${mins % 60}m`;
}

function badge(status: string): string {
  if (status === "completed") return "approved";
  if (status === "cancelled") return "rejected";
  if (status === "requested") return "submitted";
  return "under_review";
}
