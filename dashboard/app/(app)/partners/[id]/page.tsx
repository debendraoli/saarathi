"use client";

import { api, type PartnerDetail, type PartnerStatus, type PartnerType } from "@/lib/api";
import Link from "next/link";
import { use, useEffect, useState } from "react";

const DRAFT_KEYS = [
  "name",
  "legal_name",
  "partner_type",
  "status",
  "city",
  "contact_phone",
  "contact_email",
  "pan_vat",
  "commission_share",
] as const;

type Draft = {
  name: string;
  legal_name: string;
  partner_type: PartnerType;
  status: PartnerStatus;
  city: string;
  contact_phone: string;
  contact_email: string;
  pan_vat: string;
  commission_share: string;
};

// The CSS only defines a handful of `.badge.<status>` variants (approved/
// active/ok/paid → green; pending/processing → amber; rejected/danger/off/
// failed → red) — map every partner/fleet-driver status onto one of those
// instead of the raw enum value, same as the partners list page already
// does inline for its own status column.
function statusBadgeClass(status: string): string {
  if (status === "active") return "active";
  if (status === "pending" || status === "invited") return "pending";
  return "rejected"; // suspended, terminated, left
}

function draftFrom(data: PartnerDetail): Draft {
  const p = data.partner;
  return {
    name: p.name,
    legal_name: p.legal_name ?? "",
    partner_type: p.type,
    status: p.status,
    city: p.city ?? "",
    contact_phone: p.contact_phone ?? "",
    contact_email: p.contact_email ?? "",
    pan_vat: p.pan_vat ?? "",
    commission_share: p.commission_share,
  };
}

export default function PartnerDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const [data, setData] = useState<PartnerDetail | null>(null);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function load() {
    setError(null);
    try {
      const d = await api.adminPartnerDetail(id);
      setData(d);
      setDraft(draftFrom(d));
    } catch (e) {
      setError((e as Error).message);
    }
  }

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  function set<K extends keyof Draft>(key: K, value: Draft[K]) {
    setDraft((d) => (d ? { ...d, [key]: value } : d));
  }

  const dirty =
    data != null &&
    draft != null &&
    DRAFT_KEYS.some((k) => draft[k] !== draftFrom(data)[k]);

  async function save() {
    if (!data || !draft) return;
    setBusy(true);
    setError(null);
    try {
      const before = draftFrom(data);
      const body: Record<string, string | number> = {};
      if (draft.name.trim() && draft.name !== before.name) body.name = draft.name.trim();
      if (draft.legal_name !== before.legal_name) body.legal_name = draft.legal_name.trim();
      if (draft.partner_type !== before.partner_type) body.partner_type = draft.partner_type;
      if (draft.status !== before.status) body.status = draft.status;
      if (draft.city !== before.city) body.city = draft.city.trim();
      if (draft.contact_phone !== before.contact_phone) body.contact_phone = draft.contact_phone.trim();
      if (draft.contact_email !== before.contact_email) body.contact_email = draft.contact_email.trim();
      if (draft.pan_vat !== before.pan_vat) body.pan_vat = draft.pan_vat.trim();
      if (draft.commission_share !== before.commission_share) {
        body.commission_share = Number(draft.commission_share);
      }
      await api.adminUpdatePartner(id, body);
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  if (!data || !draft) {
    return (
      <div className="stack">
        <Link href="/partners" className="muted-link">← Back to partners</Link>
        {error ? <div className="error">{error}</div> : <p className="subtle">Loading…</p>}
      </div>
    );
  }

  return (
    <div className="stack">
      <Link href="/partners" className="muted-link">← Back to partners</Link>

      <div className="row">
        <h1 className="page-title" style={{ margin: 0 }}>{data.partner.name}</h1>
        <span className={`badge ${statusBadgeClass(data.partner.status)}`}>{data.partner.status}</span>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="stat-grid">
        <div className="stat">
          <div className="label">Members</div>
          <div className="value">{data.member_count}</div>
        </div>
        <div className="stat">
          <div className="label">Active drivers</div>
          <div className="value">{data.driver_count}</div>
        </div>
      </div>

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Partner details</h3>
        <p className="subtle" style={{ marginTop: -8 }}>
          Only platform staff can edit this — a partner's own portal users manage their roster and
          wallet, never this record.
        </p>
        <div className="grid-2">
          <div className="field">
            <label>Name</label>
            <input className="input" value={draft.name} onChange={(e) => set("name", e.target.value)} />
          </div>
          <div className="field">
            <label>Legal name</label>
            <input
              className="input"
              value={draft.legal_name}
              onChange={(e) => set("legal_name", e.target.value)}
            />
          </div>
          <div className="field">
            <label>Type</label>
            <select
              className="input"
              value={draft.partner_type}
              onChange={(e) => set("partner_type", e.target.value as PartnerType)}
            >
              <option value="fleet">Fleet</option>
              <option value="corporate">Corporate</option>
              <option value="agent">Agent</option>
            </select>
          </div>
          <div className="field">
            <label>Status</label>
            <select
              className="input"
              value={draft.status}
              onChange={(e) => set("status", e.target.value as PartnerStatus)}
            >
              <option value="pending">Pending</option>
              <option value="active">Active</option>
              <option value="suspended">Suspended</option>
              <option value="terminated">Terminated</option>
            </select>
          </div>
          <div className="field">
            <label>City</label>
            <input className="input" value={draft.city} onChange={(e) => set("city", e.target.value)} />
          </div>
          <div className="field">
            <label>PAN / VAT</label>
            <input
              className="input"
              value={draft.pan_vat}
              onChange={(e) => set("pan_vat", e.target.value)}
            />
          </div>
          <div className="field">
            <label>Contact phone</label>
            <input
              className="input"
              value={draft.contact_phone}
              onChange={(e) => set("contact_phone", e.target.value)}
            />
          </div>
          <div className="field">
            <label>Contact email</label>
            <input
              className="input"
              type="email"
              value={draft.contact_email}
              onChange={(e) => set("contact_email", e.target.value)}
            />
          </div>
          <div className="field">
            <label>Commission share (of the platform's ≤10%)</label>
            <input
              className="input"
              type="number"
              step="0.01"
              min={0}
              max={0.1}
              value={draft.commission_share}
              onChange={(e) => set("commission_share", e.target.value)}
            />
          </div>
        </div>
        <button className="btn primary" disabled={!dirty || busy || !draft.name.trim()} onClick={save}>
          {busy ? "Saving…" : "Save"}
        </button>
      </div>

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Fleet</h3>
        {data.drivers.length === 0 ? (
          <p className="subtle">No drivers in this fleet yet.</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Driver</th>
                <th>Phone</th>
                <th>Status</th>
                <th>Joined</th>
              </tr>
            </thead>
            <tbody>
              {data.drivers.map((d) => (
                <tr key={d.driver_user_id}>
                  <td>{d.full_name ?? "—"}</td>
                  <td>{d.phone}</td>
                  <td><span className={`badge ${statusBadgeClass(d.status)}`}>{d.status}</span></td>
                  <td>{new Date(d.joined_at).toLocaleDateString()}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
