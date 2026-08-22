"use client";

import { api, type NewPartner, type Partner } from "@/lib/api";
import { useEffect, useState } from "react";

const EMPTY: NewPartner = {
  name: "",
  owner_phone: "+977",
  partner_type: "fleet",
  city: "",
  commission_share: 0.04,
};

export default function PartnersPage() {
  const [rows, setRows] = useState<Partner[]>([]);
  const [form, setForm] = useState<NewPartner>(EMPTY);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function load() {
    setError(null);
    try {
      setRows(await api.adminListPartners());
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
      await api.adminCreatePartner({
        ...form,
        commission_share: form.commission_share ? Number(form.commission_share) : 0,
        city: form.city || null,
      });
      setForm(EMPTY);
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function setStatus(id: string, status: string) {
    try {
      await api.adminUpdatePartner(id, { status });
      await load();
    } catch (e) {
      setError((e as Error).message);
    }
  }

  function set<K extends keyof NewPartner>(key: K, value: NewPartner[K]) {
    setForm((f) => ({ ...f, [key]: value }));
  }

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Fleet Partners</h1>
        <p className="subtle">
          Onboard fleet partners and set their commission share. The share is carved from the
          platform&apos;s ≤10% — the driver&apos;s ≥90% is never touched.
        </p>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Onboard a partner</h3>
        <div className="grid-2">
          <div className="field">
            <label>Partner name</label>
            <input className="input" value={form.name} onChange={(e) => set("name", e.target.value)} placeholder="Ghorahi Moto Fleet" />
          </div>
          <div className="field">
            <label>Owner phone (E.164)</label>
            <input className="input" value={form.owner_phone} onChange={(e) => set("owner_phone", e.target.value)} placeholder="+9779800000000" />
          </div>
          <div className="field">
            <label>Type</label>
            <select className="input" value={form.partner_type} onChange={(e) => set("partner_type", e.target.value as NewPartner["partner_type"])}>
              <option value="fleet">Fleet</option>
              <option value="corporate">Corporate</option>
              <option value="agent">Agent</option>
            </select>
          </div>
          <div className="field">
            <label>City</label>
            <input className="input" value={form.city ?? ""} onChange={(e) => set("city", e.target.value)} placeholder="Ghorahi" />
          </div>
          <div className="field">
            <label>Commission share (0–0.10)</label>
            <input
              className="input"
              type="number"
              step="0.01"
              min="0"
              max="0.1"
              value={form.commission_share ?? 0}
              onChange={(e) => set("commission_share", Number(e.target.value))}
            />
          </div>
        </div>
        <button className="btn primary" style={{ marginTop: 16 }} disabled={busy || !form.name || !form.owner_phone} onClick={create}>
          {busy ? "Creating…" : "Create partner"}
        </button>
      </div>

      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Name</th>
              <th>Type</th>
              <th>City</th>
              <th>Share</th>
              <th>Status</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {rows.map((p) => (
              <tr key={p.id}>
                <td>
                  <b>{p.name}</b>
                </td>
                <td className="subtle">{p.type}</td>
                <td className="subtle">{p.city ?? "—"}</td>
                <td>{(Number(p.commission_share) * 100).toFixed(1)}%</td>
                <td>
                  <span className={`badge ${p.status === "active" ? "approved" : p.status === "suspended" ? "rejected" : "pending"}`}>
                    {p.status}
                  </span>
                </td>
                <td style={{ textAlign: "right" }}>
                  {p.status === "active" ? (
                    <button className="btn ghost" onClick={() => setStatus(p.id, "suspended")}>
                      Suspend
                    </button>
                  ) : (
                    <button className="btn ghost" onClick={() => setStatus(p.id, "active")}>
                      Activate
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td colSpan={6} className="subtle" style={{ textAlign: "center", padding: 32 }}>
                  No partners yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
