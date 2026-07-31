"use client";

import { useEffect, useState } from "react";
import { rides, type Report } from "@/lib/api";

export default function ReportsPage() {
  const [rows, setRows] = useState<Report[]>([]);
  const [error, setError] = useState<string | null>(null);

  async function load() {
    setError(null);
    try {
      setRows(await rides.listReports());
    } catch (e) {
      setError((e as Error).message);
    }
  }

  useEffect(() => {
    load();
  }, []);

  async function act(id: string, status: string) {
    await rides.resolveReport(id, status, `${status} from console`);
    await load();
  }

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Reports &amp; Grievances</h1>
        <p className="subtle">Rider/driver reports, safety first.</p>
      </div>
      {error && <div className="error">{error}</div>}
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Category</th>
              <th>Severity</th>
              <th>Detail</th>
              <th>Status</th>
              <th>Filed</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id}>
                <td>{r.category}</td>
                <td>
                  <span className={`badge ${r.severity === "high" ? "rejected" : "submitted"}`}>
                    {r.severity}
                  </span>
                </td>
                <td className="subtle">{r.detail ?? "—"}</td>
                <td>
                  <span className={`badge ${r.status === "open" ? "under_review" : "approved"}`}>
                    {r.status}
                  </span>
                </td>
                <td className="subtle">{new Date(r.created_at).toLocaleDateString()}</td>
                <td>
                  {r.status === "open" && (
                    <div className="row">
                      <button className="btn ghost" onClick={() => act(r.id, "resolved")}>
                        Resolve
                      </button>
                      <button className="btn ghost" onClick={() => act(r.id, "dismissed")}>
                        Dismiss
                      </button>
                    </div>
                  )}
                </td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td colSpan={6} className="subtle" style={{ textAlign: "center", padding: 24 }}>
                  No reports.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
