"use client";

import { Modal } from "@/components/Modal";
import {
  auth,
  rides,
  type CurrentRate,
  type NewRateProposal,
  type RateProposal,
} from "@/lib/api";
import { Plus } from "lucide-react";
import { useEffect, useState } from "react";

const VEHICLE_LABELS: Record<string, string> = {
  two_wheeler: "Two-wheeler",
  three_wheeler: "Three-wheeler",
  four_wheeler: "Four-wheeler",
};

const EMPTY: NewRateProposal = { vehicle_class: "two_wheeler", per_km_rate: 20 };

export default function RatesPage() {
  const [current, setCurrent] = useState<CurrentRate[]>([]);
  const [proposals, setProposals] = useState<RateProposal[]>([]);
  const [form, setForm] = useState<NewRateProposal>(EMPTY);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [showAdd, setShowAdd] = useState(false);
  // Unlike most maker-checker flows here (credit plans, KYC), a rate change
  // moves every fare on the platform — only a super_admin, not a plain
  // admin, may approve one. The backend enforces this too; this just hides
  // the buttons for anyone who'd get a 403 clicking them.
  const canApprove = auth.user?.role === "super_admin";

  async function load() {
    setError(null);
    try {
      const [c, p] = await Promise.all([rides.currentRates(), rides.listRateProposals()]);
      setCurrent(c);
      setProposals(p);
    } catch (e) {
      setError((e as Error).message);
    }
  }

  useEffect(() => {
    load();
  }, []);

  const pending = proposals.filter((p) => p.status === "pending");
  const decided = proposals.filter((p) => p.status !== "pending").slice(0, 20);

  async function propose() {
    setBusy(true);
    setError(null);
    try {
      await rides.proposeRate({ ...form, per_km_rate: Number(form.per_km_rate) });
      setForm(EMPTY);
      setShowAdd(false);
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function decide(id: string, approve: boolean) {
    try {
      if (approve) await rides.approveRate(id);
      else await rides.rejectRate(id, "Rejected from console");
      await load();
    } catch (e) {
      setError((e as Error).message);
    }
  }

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Base Rates</h1>
        <p className="subtle">
          Per-km rate by vehicle class. Any staff can propose a change; only a super-admin can
          approve it before it takes effect on the platform.
        </p>
      </div>
      {error && <div className="error">{error}</div>}

      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Vehicle class</th>
              <th>Current rate (NPR/km)</th>
              <th>Source</th>
            </tr>
          </thead>
          <tbody>
            {current.map((r) => (
              <tr key={r.vehicle_class}>
                <td><b>{VEHICLE_LABELS[r.vehicle_class] ?? r.vehicle_class}</b></td>
                <td>{r.per_km_rate}</td>
                <td className="subtle">{r.is_override ? "Dashboard override" : "Platform default"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="toolbar">
        <div />
        <div className="toolbar-actions">
          <button className="btn primary" onClick={() => setShowAdd(true)}>
            <Plus size={15} /> Propose rate change
          </button>
        </div>
      </div>

      {pending.length > 0 && (
        <div className="card" style={{ padding: 0 }}>
          <table>
            <thead>
              <tr>
                <th>Vehicle class</th>
                <th>Proposed rate</th>
                <th>Proposed</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {pending.map((p) => (
                <tr key={p.id}>
                  <td>{VEHICLE_LABELS[p.vehicle_class] ?? p.vehicle_class}</td>
                  <td><b>{p.per_km_rate}</b></td>
                  <td className="subtle">{new Date(p.created_at).toLocaleString()}</td>
                  <td>
                    {canApprove ? (
                      <div className="row" style={{ justifyContent: "flex-end" }}>
                        <button className="btn primary" onClick={() => decide(p.id, true)}>Approve</button>
                        <button className="btn danger" onClick={() => decide(p.id, false)}>Reject</button>
                      </div>
                    ) : (
                      <span className="subtle">awaiting super-admin</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {decided.length > 0 && (
        <div className="card" style={{ padding: 0 }}>
          <table>
            <thead>
              <tr>
                <th>Vehicle class</th>
                <th>Rate</th>
                <th>Status</th>
                <th>Reviewed</th>
              </tr>
            </thead>
            <tbody>
              {decided.map((p) => (
                <tr key={p.id}>
                  <td className="subtle">{VEHICLE_LABELS[p.vehicle_class] ?? p.vehicle_class}</td>
                  <td className="subtle">{p.per_km_rate}</td>
                  <td>
                    <span className={`badge ${p.status === "approved" ? "approved" : "rejected"}`}>
                      {p.status}
                    </span>
                  </td>
                  <td className="subtle">{p.reviewed_at ? new Date(p.reviewed_at).toLocaleString() : "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <Modal
        open={showAdd}
        onClose={() => setShowAdd(false)}
        title="Propose a rate change"
        footer={
          <>
            <button className="btn ghost" onClick={() => setShowAdd(false)}>Cancel</button>
            <button className="btn primary" disabled={busy} onClick={propose}>
              {busy ? "Submitting…" : "Submit for approval"}
            </button>
          </>
        }
      >
        <div className="grid-2">
          <div className="field">
            <label>Vehicle class</label>
            <select
              className="input"
              value={form.vehicle_class}
              onChange={(e) => setForm({ ...form, vehicle_class: e.target.value })}
            >
              {Object.entries(VEHICLE_LABELS).map(([v, label]) => (
                <option key={v} value={v}>{label}</option>
              ))}
            </select>
          </div>
          <div className="field">
            <label>Per-km rate (NPR)</label>
            <input
              className="input"
              type="number"
              step="0.5"
              value={form.per_km_rate}
              onChange={(e) => setForm({ ...form, per_km_rate: Number(e.target.value) })}
            />
          </div>
        </div>
      </Modal>
    </div>
  );
}
