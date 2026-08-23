"use client";

import { ConfirmModal } from "@/components/Modal";
import { api, auth, STAFF_ROLES, type StaffRole, type User } from "@/lib/api";
import Link from "next/link";
import { use, useEffect, useState } from "react";

export default function StaffDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const [data, setData] = useState<User | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [confirmStatus, setConfirmStatus] = useState<"deactivate" | "reactivate" | null>(null);
  const isSelf = auth.user?.id === id;

  async function load() {
    setError(null);
    try {
      const all = await api.listStaff();
      const found = all.find((u) => u.id === id);
      if (!found) throw new Error("Staff account not found.");
      setData(found);
    } catch (e) {
      setError((e as Error).message);
    }
  }

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  async function changeRole(role: StaffRole) {
    setBusy(true);
    setError(null);
    try {
      await api.updateStaff(id, { role });
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function applyStatus() {
    if (!confirmStatus) return;
    setBusy(true);
    setError(null);
    try {
      if (confirmStatus === "deactivate") await api.deactivateStaff(id);
      else await api.reactivateStaff(id);
      setConfirmStatus(null);
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  if (!data) {
    return (
      <div className="stack">
        <Link href="/staff" className="muted-link">← Back to staff</Link>
        {error ? <div className="error">{error}</div> : <p className="subtle">Loading…</p>}
      </div>
    );
  }

  const active = data.status === "active";

  return (
    <div className="stack">
      <Link href="/staff" className="muted-link">← Back to staff</Link>

      <div className="row">
        <h1 className="page-title" style={{ margin: 0 }}>{data.full_name ?? data.phone}</h1>
        <span className={`badge ${active ? "approved" : "rejected"}`}>{data.status}</span>
      </div>

      {error && <div className="error">{error}</div>}
      {isSelf && (
        <p className="subtle" style={{ margin: 0 }}>
          This is your own account — role and status changes are disabled here to avoid locking
          yourself out.
        </p>
      )}

      <div className="card">
        <dl className="kv">
          <dt>Phone</dt>
          <dd>{data.phone}</dd>
          <dt>Added</dt>
          <dd>{new Date(data.created_at).toLocaleString()}</dd>
        </dl>
      </div>

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Role</h3>
        <div className="field">
          <select
            className="input"
            value={data.role}
            disabled={busy || isSelf}
            onChange={(e) => changeRole(e.target.value as StaffRole)}
          >
            {STAFF_ROLES.map((r) => (
              <option key={r} value={r}>
                {r.replace("_", " ")}
              </option>
            ))}
          </select>
        </div>
      </div>

      <div className="row">
        {active ? (
          <button
            className="btn danger"
            disabled={busy || isSelf}
            onClick={() => setConfirmStatus("deactivate")}
          >
            Deactivate
          </button>
        ) : (
          <button
            className="btn primary"
            disabled={busy || isSelf}
            onClick={() => setConfirmStatus("reactivate")}
          >
            Reactivate
          </button>
        )}
      </div>

      <ConfirmModal
        open={confirmStatus !== null}
        onClose={() => setConfirmStatus(null)}
        onConfirm={applyStatus}
        title={confirmStatus === "deactivate" ? "Deactivate staff account?" : "Reactivate staff account?"}
        message={
          confirmStatus === "deactivate"
            ? `${data.full_name ?? data.phone} will no longer be able to sign in to the dashboard.`
            : `${data.full_name ?? data.phone} will be able to sign in to the dashboard again.`
        }
        confirmLabel={confirmStatus === "deactivate" ? "Deactivate" : "Reactivate"}
        danger={confirmStatus === "deactivate"}
        busy={busy}
      />
    </div>
  );
}
