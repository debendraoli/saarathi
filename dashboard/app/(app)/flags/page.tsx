"use client";

import { rides, type FeatureFlag } from "@/lib/api";
import { useEffect, useState } from "react";

export default function FlagsPage() {
  const [rows, setRows] = useState<FeatureFlag[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  async function load() {
    setError(null);
    try {
      setRows(await rides.listFlags());
    } catch (e) {
      setError((e as Error).message);
    }
  }

  useEffect(() => {
    load();
  }, []);

  async function toggle(f: FeatureFlag) {
    setBusy(f.key);
    setError(null);
    try {
      await rides.setFlag(f.key, !f.enabled);
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Feature Flags</h1>
        <p className="subtle">
          Runtime circuit breakers. Turning a flag off takes effect immediately — no deploy. Use these
          to shed load or freeze a misbehaving subsystem.
        </p>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Flag</th>
              <th>Description</th>
              <th>Status</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {rows.map((f) => (
              <tr key={f.key}>
                <td>
                  <b>{f.key}</b>
                </td>
                <td className="subtle">{f.description ?? "—"}</td>
                <td>
                  <span className={`badge ${f.enabled ? "ok" : "danger"}`}>
                    {f.enabled ? "ON" : "OFF"}
                  </span>
                </td>
                <td style={{ textAlign: "right" }}>
                  <button
                    className={`btn ${f.enabled ? "ghost" : "primary"}`}
                    disabled={busy === f.key}
                    onClick={() => toggle(f)}
                  >
                    {busy === f.key ? "…" : f.enabled ? "Disable" : "Enable"}
                  </button>
                </td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td colSpan={4} className="subtle" style={{ textAlign: "center" }}>
                  No flags.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
