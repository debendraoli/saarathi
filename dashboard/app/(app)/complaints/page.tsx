"use client";

import { Pagination, usePaged } from "@/components/Toolbar";
import { rides, type CancellationRow } from "@/lib/api";
import { useEffect, useState } from "react";

export default function ComplaintsPage() {
  const [rows, setRows] = useState<CancellationRow[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  function load() {
    rides
      .cancellations()
      .then(setRows)
      .catch((e) => setError((e as Error).message));
  }

  useEffect(load, []);

  async function markReviewed(id: string) {
    setBusy(id);
    setRows((prev) => prev.map((r) => (r.id === id ? { ...r, reviewed: true } : r)));
    try {
      await rides.reviewCancellation(id);
    } catch (e) {
      setError((e as Error).message);
      load(); // roll back the optimistic update
    } finally {
      setBusy(null);
    }
  }

  const { page, setPage, pageCount, total, slice } = usePaged(rows, 15);

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
              <th></th>
            </tr>
          </thead>
          <tbody>
            {slice.map((r) => (
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
                <td style={{ textAlign: "right" }}>
                  {r.reviewed ? (
                    <span className="badge approved">reviewed</span>
                  ) : (
                    <button className="btn ghost" disabled={busy === r.id} onClick={() => markReviewed(r.id)}>
                      {busy === r.id ? "…" : "Mark reviewed"}
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr><td colSpan={7} className="subtle" style={{ textAlign: "center", padding: 24 }}>No cancellations.</td></tr>
            )}
          </tbody>
        </table>
      </div>
      <Pagination page={page} pageCount={pageCount} total={total} onPage={setPage} />
    </div>
  );
}
