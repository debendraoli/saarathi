"use client";

import { Modal } from "@/components/Modal";
import { Pagination, usePaged } from "@/components/Toolbar";
import { auth, rides, type CreditPlan, type NewCreditPlan } from "@/lib/api";
import { Plus } from "lucide-react";
import { useEffect, useState } from "react";

const EMPTY: NewCreditPlan = { name: "", min_amount: 1000, max_amount: 10000, bonus_percent: 0 };

export default function CreditPlansPage() {
  const [rows, setRows] = useState<CreditPlan[]>([]);
  const [form, setForm] = useState<NewCreditPlan>(EMPTY);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [showAdd, setShowAdd] = useState(false);
  const canApprove = ["super_admin", "admin"].includes(auth.user?.role ?? "");

  async function load() {
    setError(null);
    try {
      setRows(await rides.listCreditPlans());
    } catch (e) {
      setError((e as Error).message);
    }
  }

  useEffect(() => {
    load();
  }, []);

  const { page, setPage, pageCount, total, slice } = usePaged(rows, 12);

  async function create() {
    setBusy(true);
    setError(null);
    try {
      await rides.createCreditPlan({
        ...form,
        min_amount: Number(form.min_amount),
        max_amount: Number(form.max_amount),
        bonus_percent: Number(form.bonus_percent ?? 0),
      });
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
      if (approve) await rides.approveCreditPlan(id);
      else await rides.rejectCreditPlan(id, "Rejected from console");
      await load();
    } catch (e) {
      setError((e as Error).message);
    }
  }

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Credit Plans</h1>
        <p className="subtle">
          Staff propose top-up plans; an admin or super-admin must approve before they reach riders.
        </p>
      </div>
      {error && <div className="error">{error}</div>}

      <div className="toolbar">
        <div />
        <div className="toolbar-actions">
          <button className="btn primary" onClick={() => setShowAdd(true)}>
            <Plus size={15} /> New plan
          </button>
        </div>
      </div>

      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Name</th>
              <th>Range (NPR)</th>
              <th>Bonus</th>
              <th>Status</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {slice.map((p) => (
              <tr key={p.id}>
                <td><b>{p.name}</b></td>
                <td>{p.min_amount} – {p.max_amount}</td>
                <td className="subtle">{p.bonus_percent}%</td>
                <td>
                  <span className={`badge ${p.status === "active" ? "approved" : p.status === "rejected" ? "rejected" : "under_review"}`}>
                    {p.status}
                  </span>
                </td>
                <td>
                  {p.status === "pending" && canApprove && (
                    <div className="row" style={{ justifyContent: "flex-end" }}>
                      <button className="btn primary" onClick={() => decide(p.id, true)}>Approve</button>
                      <button className="btn danger" onClick={() => decide(p.id, false)}>Reject</button>
                    </div>
                  )}
                  {p.status === "pending" && !canApprove && <span className="subtle">awaiting admin</span>}
                </td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr><td colSpan={5} className="subtle" style={{ textAlign: "center", padding: 24 }}>No plans yet.</td></tr>
            )}
          </tbody>
        </table>
      </div>

      <Pagination page={page} pageCount={pageCount} total={total} onPage={setPage} />

      <Modal
        open={showAdd}
        onClose={() => setShowAdd(false)}
        title="New credit plan"
        footer={
          <>
            <button className="btn ghost" onClick={() => setShowAdd(false)}>Cancel</button>
            <button className="btn primary" disabled={busy} onClick={create}>
              {busy ? "Submitting…" : "Submit for approval"}
            </button>
          </>
        }
      >
        <div className="grid-2">
          <div className="field">
            <label>Name</label>
            <input className="input" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="Standard" />
          </div>
          <div className="field">
            <label>Bonus %</label>
            <input className="input" type="number" value={form.bonus_percent} onChange={(e) => setForm({ ...form, bonus_percent: Number(e.target.value) })} />
          </div>
          <div className="field">
            <label>Min amount (NPR)</label>
            <input className="input" type="number" value={form.min_amount} onChange={(e) => setForm({ ...form, min_amount: Number(e.target.value) })} />
          </div>
          <div className="field">
            <label>Max amount (NPR)</label>
            <input className="input" type="number" value={form.max_amount} onChange={(e) => setForm({ ...form, max_amount: Number(e.target.value) })} />
          </div>
        </div>
      </Modal>
    </div>
  );
}
