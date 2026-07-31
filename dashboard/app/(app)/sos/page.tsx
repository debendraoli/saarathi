"use client";

import { rides, type SosIncident } from "@/lib/api";
import { useEffect, useState } from "react";

export default function SosPage() {
  const [rows, setRows] = useState<SosIncident[]>([]);
  const [error, setError] = useState<string | null>(null);

  async function load() {
    setError(null);
    try {
      setRows(await rides.listSos());
    } catch (e) {
      setError((e as Error).message);
    }
  }

  useEffect(() => {
    load();
    const t = setInterval(load, 5000); // live-ish refresh
    return () => clearInterval(t);
  }, []);

  async function resolve(id: string) {
    await rides.resolveSos(id, "Resolved from console");
    await load();
  }

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">SOS Console</h1>
        <p className="subtle">Active emergency alerts. Refreshes automatically.</p>
      </div>
      {error && <div className="error">{error}</div>}
      {rows.length === 0 ? (
        <div className="card">
          <p className="subtle" style={{ margin: 0 }}>No active incidents. 🟢</p>
        </div>
      ) : (
        rows.map((s) => (
          <div key={s.id} className="card" style={{ borderColor: "var(--red)" }}>
            <div className="row">
              <span className="badge rejected">SOS ACTIVE</span>
              <span className="subtle">{new Date(s.created_at).toLocaleString()}</span>
            </div>
            <dl className="kv" style={{ marginTop: 12 }}>
              <dt>User</dt>
              <dd>{s.user_id}</dd>
              <dt>Trip</dt>
              <dd>{s.trip_id ?? "—"}</dd>
              <dt>Location</dt>
              <dd>
                {s.lat != null && s.lng != null ? (
                  <a
                    className="muted-link"
                    href={`https://www.openstreetmap.org/?mlat=${s.lat}&mlon=${s.lng}#map=17/${s.lat}/${s.lng}`}
                    target="_blank"
                    rel="noreferrer"
                  >
                    {s.lat.toFixed(5)}, {s.lng.toFixed(5)} ↗
                  </a>
                ) : (
                  "—"
                )}
              </dd>
              <dt>Note</dt>
              <dd>{s.note ?? "—"}</dd>
            </dl>
            <button className="btn primary" style={{ marginTop: 12 }} onClick={() => resolve(s.id)}>
              Mark resolved
            </button>
          </div>
        ))
      )}
    </div>
  );
}
