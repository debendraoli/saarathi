"use client";

import {
  api,
  rides,
  type FleetAnalytics,
  type FleetDriver,
  type Membership,
  type PartnerMemberRow,
} from "@/lib/api";
import { useCallback, useEffect, useState } from "react";

const MEMBER_ROLES = ["admin", "manager", "dispatcher", "finance", "support", "viewer"];

export default function PartnerPortalPage() {
  const [memberships, setMemberships] = useState<Membership[]>([]);
  const [pid, setPid] = useState<string | null>(null);
  const [members, setMembers] = useState<PartnerMemberRow[]>([]);
  const [drivers, setDrivers] = useState<FleetDriver[]>([]);
  const [stats, setStats] = useState<FleetAnalytics | null>(null);
  const [error, setError] = useState<string | null>(null);

  const [invPhone, setInvPhone] = useState("+977");
  const [invRole, setInvRole] = useState("manager");
  const [drvPhone, setDrvPhone] = useState("+977");

  const active = memberships.find((m) => m.partner_id === pid);
  const canManageMembers = active?.role === "owner" || active?.role === "admin";
  const canManageDrivers = canManageMembers || active?.role === "manager";

  useEffect(() => {
    api
      .partnerMemberships()
      .then((m) => {
        setMemberships(m);
        if (m.length && !pid) setPid(m[0].partner_id);
      })
      .catch((e) => setError((e as Error).message));
  }, [pid]);

  const loadFleet = useCallback(async (p: string) => {
    setError(null);
    try {
      const [mem, drv, an] = await Promise.all([
        api.partnerMembers(p),
        api.partnerDrivers(p),
        rides.partnerAnalytics(p),
      ]);
      setMembers(mem);
      setDrivers(drv);
      setStats(an);
    } catch (e) {
      setError((e as Error).message);
    }
  }, []);

  useEffect(() => {
    if (pid) loadFleet(pid);
  }, [pid, loadFleet]);

  async function invite() {
    if (!pid) return;
    try {
      await api.partnerInviteMember(pid, invPhone.trim(), invRole);
      setInvPhone("+977");
      await loadFleet(pid);
    } catch (e) {
      setError((e as Error).message);
    }
  }

  async function addDriver() {
    if (!pid) return;
    try {
      await api.partnerAddDriver(pid, { phone: drvPhone.trim() });
      setDrvPhone("+977");
      await loadFleet(pid);
    } catch (e) {
      setError((e as Error).message);
    }
  }

  async function releaseDriver(driverUserId: string) {
    if (!pid) return;
    try {
      await api.partnerSetDriverStatus(pid, driverUserId, "left");
      await loadFleet(pid);
    } catch (e) {
      setError((e as Error).message);
    }
  }

  if (memberships.length === 0) {
    return (
      <div className="stack">
        <h1 className="page-title">Partner Portal</h1>
        <div className="card subtle">
          {error ?? "You are not a member of any fleet. Ask a platform admin to onboard your partner."}
        </div>
      </div>
    );
  }

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Partner Portal</h1>
        <p className="subtle">Manage your fleet&apos;s staff and drivers, and track fleet performance.</p>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="row" style={{ flexWrap: "wrap" }}>
        {memberships.map((m) => (
          <button
            key={m.partner_id}
            className={`btn ${m.partner_id === pid ? "primary" : "ghost"}`}
            onClick={() => setPid(m.partner_id)}
          >
            {m.name} · <b>{m.role}</b>
          </button>
        ))}
      </div>

      {stats && (
        <div className="stat-grid">
          <Stat label="Active drivers" value={stats.active_drivers} />
          <Stat label="Completed trips" value={stats.trips.completed} />
          <Stat label="Fleet GMV" value={`NPR ${Number(stats.money.gmv).toLocaleString()}`} />
          <Stat label="Driver earnings" value={`NPR ${Number(stats.money.driver_earnings).toLocaleString()}`} />
        </div>
      )}

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Fleet drivers</h3>
        {canManageDrivers && (
          <div className="row" style={{ marginBottom: 12 }}>
            <input className="input" style={{ maxWidth: 240 }} value={drvPhone} onChange={(e) => setDrvPhone(e.target.value)} placeholder="driver phone +977…" />
            <button className="btn primary" onClick={addDriver}>
              Add driver
            </button>
          </div>
        )}
        <table>
          <thead>
            <tr>
              <th>Phone</th>
              <th>Name</th>
              <th>KYC</th>
              <th>Status</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {drivers.map((d) => (
              <tr key={d.driver_user_id}>
                <td>{d.phone}</td>
                <td>{d.full_name ?? "—"}</td>
                <td>
                  <span className={`badge ${d.kyc_status ?? "pending"}`}>{d.kyc_status ?? "—"}</span>
                </td>
                <td className="subtle">{d.status}</td>
                <td style={{ textAlign: "right" }}>
                  {canManageDrivers && d.status !== "left" && (
                    <button className="btn ghost" onClick={() => releaseDriver(d.driver_user_id)}>
                      Release
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {drivers.length === 0 && (
              <tr>
                <td colSpan={5} className="subtle" style={{ textAlign: "center" }}>
                  No drivers in this fleet yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Staff members</h3>
        {canManageMembers && (
          <div className="row" style={{ marginBottom: 12 }}>
            <input className="input" style={{ maxWidth: 220 }} value={invPhone} onChange={(e) => setInvPhone(e.target.value)} placeholder="staff phone +977…" />
            <select className="input" style={{ maxWidth: 160 }} value={invRole} onChange={(e) => setInvRole(e.target.value)}>
              {MEMBER_ROLES.map((r) => (
                <option key={r} value={r}>
                  {r}
                </option>
              ))}
            </select>
            <button className="btn primary" onClick={invite}>
              Invite
            </button>
          </div>
        )}
        <table>
          <thead>
            <tr>
              <th>Phone</th>
              <th>Name</th>
              <th>Role</th>
            </tr>
          </thead>
          <tbody>
            {members.map((m) => (
              <tr key={m.user_id}>
                <td>{m.phone}</td>
                <td>{m.full_name ?? "—"}</td>
                <td>
                  <span className="badge under_review">{m.role}</span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="stat">
      <div className="label">{label}</div>
      <div className="value">{value}</div>
    </div>
  );
}
