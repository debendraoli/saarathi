"use client";

import { Modal } from "@/components/Modal";
import { Pagination, usePaged } from "@/components/Toolbar";
import { api, STAFF_ROLES, type StaffRole, type User } from "@/lib/api";
import { Plus } from "lucide-react";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";

const EMPTY = { phone: "", full_name: "", role: "support" as StaffRole };

export default function StaffPage() {
  const router = useRouter();
  const [rows, setRows] = useState<User[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [showAdd, setShowAdd] = useState(false);
  const [form, setForm] = useState(EMPTY);
  const [busy, setBusy] = useState(false);

  async function load() {
    setError(null);
    try {
      setRows(await api.listStaff());
    } catch (e) {
      setError((e as Error).message);
    }
  }

  useEffect(() => {
    load();
  }, []);

  const { page, setPage, pageCount, total, slice } = usePaged(rows, 15);

  async function create() {
    setBusy(true);
    setError(null);
    try {
      await api.createStaff(form);
      setForm(EMPTY);
      setShowAdd(false);
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Staff</h1>
        <p className="subtle">Dashboard operator accounts — every role except rider/driver.</p>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="toolbar">
        <div />
        <div className="toolbar-actions">
          <button className="btn primary" onClick={() => setShowAdd(true)}>
            <Plus size={15} /> Add staff
          </button>
        </div>
      </div>

      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Name</th>
              <th>Phone</th>
              <th>Role</th>
              <th>Status</th>
              <th>Added</th>
            </tr>
          </thead>
          <tbody>
            {slice.map((r) => (
              <tr key={r.id} onClick={() => router.push(`/staff/${r.id}`)}>
                <td><b>{r.full_name ?? "—"}</b></td>
                <td>{r.phone}</td>
                <td className="subtle">{r.role.replace("_", " ")}</td>
                <td>
                  <span className={`badge ${r.status === "active" ? "approved" : "rejected"}`}>
                    {r.status}
                  </span>
                </td>
                <td className="subtle">{new Date(r.created_at).toLocaleDateString()}</td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td colSpan={5} className="subtle" style={{ textAlign: "center", padding: 32 }}>
                  No staff accounts yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <Pagination page={page} pageCount={pageCount} total={total} onPage={setPage} />

      <Modal
        open={showAdd}
        onClose={() => setShowAdd(false)}
        title="Add staff"
        footer={
          <>
            <button className="btn ghost" onClick={() => setShowAdd(false)} disabled={busy}>
              Cancel
            </button>
            <button
              className="btn primary"
              onClick={create}
              disabled={busy || !form.phone.trim() || !form.full_name.trim()}
            >
              {busy ? "Creating…" : "Create"}
            </button>
          </>
        }
      >
        <div className="field">
          <label>Phone (E.164)</label>
          <input
            className="input"
            value={form.phone}
            onChange={(e) => setForm({ ...form, phone: e.target.value })}
            placeholder="+9779800000000"
          />
        </div>
        <div className="field">
          <label>Full name</label>
          <input
            className="input"
            value={form.full_name}
            onChange={(e) => setForm({ ...form, full_name: e.target.value })}
          />
        </div>
        <div className="field">
          <label>Role</label>
          <select
            className="input"
            value={form.role}
            onChange={(e) => setForm({ ...form, role: e.target.value as StaffRole })}
          >
            {STAFF_ROLES.map((r) => (
              <option key={r} value={r}>
                {r.replace("_", " ")}
              </option>
            ))}
          </select>
        </div>
        <p className="subtle" style={{ marginTop: 0 }}>
          The new staff member logs in themselves with this phone via the usual OTP flow — nothing
          further to send them.
        </p>
      </Modal>
    </div>
  );
}
