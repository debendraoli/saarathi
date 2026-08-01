"use client";

import { rides, type RideRow } from "@/lib/api";
import { useEffect, useState } from "react";

const TABS = ["all", "requested", "accepted", "in_progress", "completed", "cancelled"];

export default function RidesPage() {
  const [status, setStatus] = useState("all");
  const [rows, setRows] = useState<RideRow[]>([]);
  const [error, setError] = useState<string | null>(null);

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

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Rides History</h1>
        <p className="subtle">Every ride with status, rating, payment, and cancellation detail.</p>
      </div>

      <div className="row">
        {TABS.map((t) => (
          <button key={t} className={`btn ${status === t ? "primary" : "ghost"}`} onClick={() => setStatus(t)}>
            {t.replace("_", " ")}
          </button>
        ))}
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
              <th>Cancellation</th>
              <th>When</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id}>
                <td>{r.rider_name ?? r.rider_id.slice(0, 8)}</td>
                <td>{r.driver_name ?? (r.driver_id ? r.driver_id.slice(0, 8) : "—")}</td>
                <td>
                  <span className={`badge ${badge(r.status)}`}>{r.status.replace("_", " ")}</span>
                </td>
                <td>NPR {r.final_fare}</td>
                <td className="subtle">{r.payment_method}</td>
                <td>{r.driver_stars ? `${"★".repeat(r.driver_stars)}` : "—"}</td>
                <td className="subtle">
                  {r.cancel_reason ? `${r.cancelled_by_role}: ${r.cancel_reason}` : "—"}
                </td>
                <td className="subtle">{new Date(r.created_at).toLocaleString()}</td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr><td colSpan={8} className="subtle" style={{ textAlign: "center", padding: 24 }}>No rides.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function badge(status: string): string {
  if (status === "completed") return "approved";
  if (status === "cancelled") return "rejected";
  if (status === "requested") return "submitted";
  return "under_review";
}
