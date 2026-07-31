"use client";

import { useEffect, useState } from "react";
import { rides, type LedgerEntry } from "@/lib/api";

export default function LedgerPage() {
  const [rows, setRows] = useState<LedgerEntry[]>([]);
  const [intact, setIntact] = useState<boolean | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      try {
        const [entries, v] = await Promise.all([rides.listLedger(), rides.verifyLedger()]);
        setRows(entries);
        setIntact(v.chain_intact);
      } catch (e) {
        setError((e as Error).message);
      }
    })();
  }, []);

  return (
    <div className="stack">
      <div className="row">
        <h1 className="page-title" style={{ margin: 0 }}>Ledger</h1>
        {intact != null && (
          <span className={`badge ${intact ? "approved" : "rejected"}`}>
            {intact ? "chain intact" : "chain broken"}
          </span>
        )}
      </div>
      <p className="subtle" style={{ marginTop: -12 }}>
        Append-only, hash-chained. Every completed trip settles here.
      </p>
      {error && <div className="error">{error}</div>}
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>#</th>
              <th>Gross</th>
              <th>Commission</th>
              <th>Fund</th>
              <th>Driver</th>
              <th>Method</th>
              <th>Hash</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((e) => (
              <tr key={e.seq}>
                <td>{e.seq}</td>
                <td>NPR {e.gross}</td>
                <td className="subtle">{e.commission}</td>
                <td className="subtle">{e.accident_fund}</td>
                <td>NPR {e.driver_payout}</td>
                <td>
                  <span className="badge submitted">{e.payment_method}</span>
                </td>
                <td className="subtle" title={e.entry_hash}>
                  {e.entry_hash.slice(0, 10)}…
                </td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td colSpan={7} className="subtle" style={{ textAlign: "center", padding: 24 }}>
                  No entries yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
