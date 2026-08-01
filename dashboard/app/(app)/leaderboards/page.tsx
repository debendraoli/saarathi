"use client";

import { useEffect, useState } from "react";
import { rides, type LeaderRow } from "@/lib/api";

const FILTERS = [
  { role: "driver", by: "earnings", label: "Top earners", unit: "NPR" },
  { role: "driver", by: "rating", label: "Best rated", unit: "★" },
  { role: "driver", by: "cancellations", label: "Drivers — most cancels", unit: "" },
  { role: "rider", by: "cancellations", label: "Riders — most cancels", unit: "" },
  { role: "rider", by: "trips", label: "Riders — most trips", unit: "" },
];

export default function LeaderboardsPage() {
  const [active, setActive] = useState(0);
  const [rows, setRows] = useState<LeaderRow[]>([]);
  const [error, setError] = useState<string | null>(null);

  const f = FILTERS[active];

  useEffect(() => {
    let live = true;
    setError(null);
    rides
      .leaderboard(f.role, f.by)
      .then((r) => live && setRows(r))
      .catch((e) => live && setError((e as Error).message));
    return () => {
      live = false;
    };
  }, [f.role, f.by]);

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Leaderboards</h1>
        <p className="subtle">Filter riders and drivers by performance.</p>
      </div>

      <div className="row" style={{ flexWrap: "wrap" }}>
        {FILTERS.map((x, i) => (
          <button key={x.label} className={`btn ${active === i ? "primary" : "ghost"}`} onClick={() => setActive(i)}>
            {x.label}
          </button>
        ))}
      </div>

      {error && <div className="error">{error}</div>}

      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>#</th>
              <th>Name</th>
              <th>Phone</th>
              <th style={{ textAlign: "right" }}>{f.label}</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={r.user_id}>
                <td>{i + 1}</td>
                <td>{r.name ?? "—"}</td>
                <td className="subtle">{r.phone}</td>
                <td style={{ textAlign: "right" }}>
                  {f.unit === "NPR" ? `NPR ${r.value.toFixed(2)}` : f.unit === "★" ? `${r.value.toFixed(2)} ★` : Math.round(r.value)}
                </td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr><td colSpan={4} className="subtle" style={{ textAlign: "center", padding: 24 }}>No data.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
