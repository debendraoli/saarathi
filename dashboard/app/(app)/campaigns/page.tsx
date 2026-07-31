"use client";

import { rides, type Campaign, type NewCampaign } from "@/lib/api";
import { useEffect, useState } from "react";

const EMPTY: NewCampaign = {
  code: "",
  title: "",
  audience: "rider",
  kind: "percent",
  value: 10,
  min_fare: 0,
  max_discount: null,
  vehicle_class: null,
  usage_limit: null,
};

export default function CampaignsPage() {
  const [rows, setRows] = useState<Campaign[]>([]);
  const [form, setForm] = useState<NewCampaign>(EMPTY);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function load() {
    setError(null);
    try {
      setRows(await rides.listCampaigns());
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
      await rides.createCampaign({
        ...form,
        value: Number(form.value),
        min_fare: form.min_fare ? Number(form.min_fare) : 0,
        max_discount: form.max_discount ? Number(form.max_discount) : null,
        usage_limit: form.usage_limit ? Number(form.usage_limit) : null,
        vehicle_class: form.vehicle_class || null,
      });
      setForm(EMPTY);
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function deactivate(id: string) {
    try {
      await rides.deactivateCampaign(id);
      await load();
    } catch (e) {
      setError((e as Error).message);
    }
  }

  function set<K extends keyof NewCampaign>(key: K, value: NewCampaign[K]) {
    setForm((f) => ({ ...f, [key]: value }));
  }

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Campaigns &amp; Offers</h1>
        <p className="subtle">
          Rider discounts and driver bonuses. Promos are platform-funded — the driver&apos;s payout is
          never reduced.
        </p>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="card">
        <h3 style={{ marginTop: 0 }}>New campaign</h3>
        <div className="grid-2">
          <div className="field">
            <label>Code</label>
            <input
              className="input"
              value={form.code}
              onChange={(e) => set("code", e.target.value.toUpperCase())}
              placeholder="DASHAIN25"
            />
          </div>
          <div className="field">
            <label>Title</label>
            <input
              className="input"
              value={form.title}
              onChange={(e) => set("title", e.target.value)}
              placeholder="Dashain festival offer"
            />
          </div>
          <div className="field">
            <label>Audience</label>
            <select
              className="input"
              value={form.audience}
              onChange={(e) => set("audience", e.target.value as NewCampaign["audience"])}
            >
              <option value="rider">Rider discount</option>
              <option value="driver">Driver bonus</option>
            </select>
          </div>
          <div className="field">
            <label>Type</label>
            <select
              className="input"
              value={form.kind}
              onChange={(e) => set("kind", e.target.value as NewCampaign["kind"])}
            >
              <option value="percent">Percent (%)</option>
              <option value="flat">Flat (NPR)</option>
            </select>
          </div>
          <div className="field">
            <label>Value {form.kind === "percent" ? "(%)" : "(NPR)"}</label>
            <input
              className="input"
              type="number"
              value={form.value}
              onChange={(e) => set("value", Number(e.target.value))}
            />
          </div>
          <div className="field">
            <label>Max discount (NPR, optional)</label>
            <input
              className="input"
              type="number"
              value={form.max_discount ?? ""}
              onChange={(e) => set("max_discount", e.target.value ? Number(e.target.value) : null)}
              placeholder="e.g. 50"
            />
          </div>
          <div className="field">
            <label>Min fare (NPR)</label>
            <input
              className="input"
              type="number"
              value={form.min_fare ?? 0}
              onChange={(e) => set("min_fare", Number(e.target.value))}
            />
          </div>
          <div className="field">
            <label>Usage limit (optional)</label>
            <input
              className="input"
              type="number"
              value={form.usage_limit ?? ""}
              onChange={(e) => set("usage_limit", e.target.value ? Number(e.target.value) : null)}
              placeholder="unlimited"
            />
          </div>
          <div className="field">
            <label>Vehicle class (optional)</label>
            <select
              className="input"
              value={form.vehicle_class ?? ""}
              onChange={(e) => set("vehicle_class", e.target.value || null)}
            >
              <option value="">Any</option>
              <option value="two_wheeler">Two-wheeler</option>
              <option value="four_wheeler">Four-wheeler</option>
            </select>
          </div>
        </div>
        <button className="btn primary" disabled={busy} onClick={create}>
          {busy ? "Creating…" : "Create campaign"}
        </button>
      </div>

      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Code</th>
              <th>Title</th>
              <th>Audience</th>
              <th>Benefit</th>
              <th>Used</th>
              <th>Status</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {rows.map((c) => (
              <tr key={c.id}>
                <td>
                  <b>{c.code}</b>
                </td>
                <td>{c.title}</td>
                <td>{c.audience}</td>
                <td>
                  {c.kind === "percent" ? `${c.value}%` : `NPR ${c.value}`}
                  {c.max_discount ? ` (max ${c.max_discount})` : ""}
                </td>
                <td className="subtle">
                  {c.used_count}
                  {c.usage_limit ? ` / ${c.usage_limit}` : ""}
                </td>
                <td>
                  <span className={`badge ${c.active ? "approved" : "rejected"}`}>
                    {c.active ? "active" : "inactive"}
                  </span>
                </td>
                <td>
                  {c.active && (
                    <button className="btn ghost" onClick={() => deactivate(c.id)}>
                      Deactivate
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td colSpan={7} className="subtle" style={{ textAlign: "center", padding: 32 }}>
                  No campaigns yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
