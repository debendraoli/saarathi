"use client";

import { useEffect, useState } from "react";
import { rides, type Payout } from "@/lib/api";

export default function PayoutsPage() {
  const [rows, setRows] = useState<Payout[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    rides
      .listPayouts()
      .then(setRows)
      .catch((e) => setError((e as Error).message));
  }, []);

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Payouts</h1>
        <p className="subtle">Driver withdrawals of their earnings balance.</p>
      </div>
      {error && <div className="error">{error}</div>}
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Driver</th>
              <th>Amount</th>
              <th>Status</th>
              <th>Reference</th>
              <th>When</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((p) => (
              <tr key={p.id}>
                <td>{p.driver_id.slice(0, 8)}…</td>
                <td>NPR {p.amount}</td>
                <td>
                  <span className={`badge ${p.status === "paid" ? "approved" : "under_review"}`}>
                    {p.status}
                  </span>
                </td>
                <td className="subtle">{p.reference ?? "—"}</td>
                <td className="subtle">{new Date(p.created_at).toLocaleString()}</td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td colSpan={5} className="subtle" style={{ textAlign: "center", padding: 24 }}>
                  No payouts yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
