"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { api, type DriverListItem } from "@/lib/api";

const TABS = [
  { key: "queue", label: "Review queue" },
  { key: "approved", label: "Approved" },
  { key: "rejected", label: "Rejected" },
];

export default function DriversPage() {
  const router = useRouter();
  const [tab, setTab] = useState("queue");
  const [rows, setRows] = useState<DriverListItem[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError(null);
    api
      .listDrivers(tab)
      .then((data) => active && setRows(data))
      .catch((e) => active && setError((e as Error).message))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [tab]);

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Driver Verification</h1>
        <p className="subtle">Review KYC submissions and approve or reject drivers.</p>
      </div>

      <div className="row">
        {TABS.map((t) => (
          <button
            key={t.key}
            className={`btn ${tab === t.key ? "primary" : "ghost"}`}
            onClick={() => setTab(t.key)}
          >
            {t.label}
          </button>
        ))}
      </div>

      {error && <div className="error">{error}</div>}

      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Name</th>
              <th>Phone</th>
              <th>License</th>
              <th>Status</th>
              <th>Submitted</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((d) => (
              <tr key={d.id} onClick={() => router.push(`/drivers/${d.id}`)}>
                <td>{d.full_name ?? "—"}</td>
                <td>{d.phone}</td>
                <td>{d.license_number ?? "—"}</td>
                <td>
                  <span className={`badge ${d.kyc_status}`}>{label(d.kyc_status)}</span>
                </td>
                <td className="subtle">{fmtDate(d.created_at)}</td>
              </tr>
            ))}
            {!loading && rows.length === 0 && (
              <tr>
                <td colSpan={5} className="subtle" style={{ textAlign: "center", padding: 32 }}>
                  Nothing here.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function label(s: string) {
  return s.replace("_", " ");
}

function fmtDate(iso: string) {
  return new Date(iso).toLocaleString();
}
