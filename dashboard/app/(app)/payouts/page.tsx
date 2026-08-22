"use client";

import { Pagination, usePaged } from "@/components/Toolbar";
import { rides, type Payout } from "@/lib/api";
import { useEffect, useState } from "react";

export default function PayoutsPage() {
  const [rows, setRows] = useState<Payout[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    rides
      .listPayouts()
      .then(setRows)
      .catch((e) => setError((e as Error).message));
  }, []);

  const { page, setPage, pageCount, total, slice } = usePaged(rows, 20);

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Payouts</h1>
        <p className="subtle">
          Driver withdrawals. TDS is withheld at source; each payout settles via the PSP callback.
        </p>
      </div>
      {error && <div className="error">{error}</div>}
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Driver</th>
              <th>Gross</th>
              <th>TDS</th>
              <th>Net</th>
              <th>Status</th>
              <th>When</th>
            </tr>
          </thead>
          <tbody>
            {slice.map((p) => (
              <tr key={p.id}>
                <td>{p.driver_id.slice(0, 8)}…</td>
                <td>NPR {p.amount}</td>
                <td className="subtle">NPR {p.tds_amount}</td>
                <td>
                  <b>NPR {p.net_amount ?? p.amount}</b>
                </td>
                <td>
                  <span className={`badge ${p.status}`}>{p.status}</span>
                </td>
                <td className="subtle">{new Date(p.created_at).toLocaleString()}</td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td colSpan={6} className="subtle" style={{ textAlign: "center", padding: 24 }}>
                  No payouts yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <Pagination page={page} pageCount={pageCount} total={total} onPage={setPage} />
    </div>
  );
}
