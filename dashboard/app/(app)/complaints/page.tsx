"use client";

import { rides, type RideRow } from "@/lib/api";
import { useEffect, useState } from "react";

export default function ComplaintsPage() {
  const [rows, setRows] = useState<RideRow[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    rides
      .cancellations()
      .then(setRows)
      .catch((e) => setError((e as Error).message));
  }, []);

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Complaints — Cancellations</h1>
        <p className="subtle">Cancelled rides with the reason and who cancelled.</p>
      </div>
      {error && <div className="error">{error}</div>}
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Rider</th>
              <th>Driver</th>
              <th>Cancelled by</th>
              <th>Reason</th>
              <th>Fare</th>
              <th>When</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id}>
                <td>{r.rider_name ?? r.rider_id.slice(0, 8)}</td>
                <td>{r.driver_name ?? (r.driver_id ? r.driver_id.slice(0, 8) : "—")}</td>
                <td>
                  <span className={`badge ${r.cancelled_by_role === "rider" ? "under_review" : "submitted"}`}>
                    {r.cancelled_by_role ?? "—"}
                  </span>
                </td>
                <td>{r.cancel_reason ?? "—"}</td>
                <td className="subtle">NPR {r.final_fare}</td>
                <td className="subtle">{new Date(r.created_at).toLocaleString()}</td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr><td colSpan={6} className="subtle" style={{ textAlign: "center", padding: 24 }}>No cancellations.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
