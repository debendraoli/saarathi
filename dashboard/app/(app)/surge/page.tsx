"use client";

import { rides, type NewSurgeWindow, type SurgeWindow } from "@/lib/api";
import { useEffect, useState } from "react";

function toMinutes(hhmm: string): number {
  const [h, m] = hhmm.split(":").map(Number);
  return (h || 0) * 60 + (m || 0);
}
function fromMinutes(min: number): string {
  const h = Math.floor(min / 60) % 24;
  const m = min % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

export default function SurgePage() {
  const [rows, setRows] = useState<SurgeWindow[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [label, setLabel] = useState("Evening rush");
  const [start, setStart] = useState("17:00");
  const [end, setEnd] = useState("20:00");
  const [multiplier, setMultiplier] = useState(1.15);
  const [vclass, setVclass] = useState<string>("");

  async function load() {
    setError(null);
    try {
      setRows(await rides.listSurge());
    } catch (e) {
      setError((e as Error).message);
    }
  }

  useEffect(() => {
    load();
  }, []);

  async function create() {
    setBusy(true);
    setError(null);
    try {
      const w: NewSurgeWindow = {
        label,
        start_minute: toMinutes(start),
        end_minute: toMinutes(end),
        multiplier: Number(multiplier),
        vehicle_class: vclass || null,
      };
      await rides.createSurge(w);
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function deactivate(id: string) {
    try {
      await rides.deactivateSurge(id);
      await load();
    } catch (e) {
      setError((e as Error).message);
    }
  }

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Surge Hours</h1>
        <p className="subtle">
          Time-of-day surcharge windows. Whatever you set here is still hard-clamped to the legal
          +20% ceiling by the pricing engine — surge can never breach the law.
        </p>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="card">
        <h3 style={{ marginTop: 0 }}>New surge window</h3>
        <div className="grid-2">
          <div className="field">
            <label>Label</label>
            <input className="input" value={label} onChange={(e) => setLabel(e.target.value)} />
          </div>
          <div className="field">
            <label>Multiplier (max 1.20)</label>
            <input
              className="input"
              type="number"
              step="0.01"
              min="1"
              max="1.2"
              value={multiplier}
              onChange={(e) => setMultiplier(Number(e.target.value))}
            />
          </div>
          <div className="field">
            <label>Start time</label>
            <input className="input" type="time" value={start} onChange={(e) => setStart(e.target.value)} />
          </div>
          <div className="field">
            <label>End time</label>
            <input className="input" type="time" value={end} onChange={(e) => setEnd(e.target.value)} />
          </div>
          <div className="field">
            <label>Vehicle class (optional)</label>
            <select className="input" value={vclass} onChange={(e) => setVclass(e.target.value)}>
              <option value="">Any</option>
              <option value="two_wheeler">Two-wheeler</option>
              <option value="four_wheeler">Four-wheeler</option>
            </select>
          </div>
        </div>
        <button className="btn primary" style={{ marginTop: 16 }} disabled={busy} onClick={create}>
          {busy ? "Saving…" : "Add window"}
        </button>
      </div>

      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Label</th>
              <th>Window</th>
              <th>×</th>
              <th>Vehicle</th>
              <th>Status</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {rows.map((w) => (
              <tr key={w.id}>
                <td>
                  <b>{w.label}</b>
                </td>
                <td>
                  {fromMinutes(w.start_minute)} – {fromMinutes(w.end_minute)}
                </td>
                <td>{Number(w.multiplier).toFixed(2)}</td>
                <td className="subtle">{w.vehicle_class ?? "any"}</td>
                <td>
                  <span className={`badge ${w.active ? "ok" : "off"}`}>
                    {w.active ? "active" : "off"}
                  </span>
                </td>
                <td style={{ textAlign: "right" }}>
                  {w.active && (
                    <button className="btn ghost" onClick={() => deactivate(w.id)}>
                      Deactivate
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td colSpan={6} className="subtle" style={{ textAlign: "center" }}>
                  No surge windows — fares run at the base rate.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
