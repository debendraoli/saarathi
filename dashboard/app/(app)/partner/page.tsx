"use client";

import { BarChart, Donut, Kpi } from "@/components/Charts";
import { ConfirmModal } from "@/components/Modal";
import {
    api,
    rides,
    type FleetAnalytics,
    type FleetCampaign,
    type FleetDriver,
    type FleetRider,
    type Membership,
    type PartnerLedgerRow,
    type PartnerMemberRow,
    type PartnerWallet,
} from "@/lib/api";
import { Banknote, Car, TrendingUp, Wallet } from "lucide-react";
import { useCallback, useEffect, useState } from "react";

const MEMBER_ROLES = ["admin", "manager", "dispatcher", "finance", "support", "viewer"];

export default function PartnerPortalPage() {
  const [memberships, setMemberships] = useState<Membership[]>([]);
  const [pid, setPid] = useState<string | null>(null);
  const [members, setMembers] = useState<PartnerMemberRow[]>([]);
  const [drivers, setDrivers] = useState<FleetDriver[]>([]);
  const [stats, setStats] = useState<FleetAnalytics | null>(null);
  const [wallet, setWallet] = useState<PartnerWallet | null>(null);
  const [ledger, setLedger] = useState<PartnerLedgerRow[]>([]);
  const [campaigns, setCampaigns] = useState<FleetCampaign[]>([]);
    const [riders, setRiders] = useState<FleetRider[]>([]);
    const [chainIntact, setChainIntact] = useState<boolean | null>(null);
  const [error, setError] = useState<string | null>(null);

  const [invPhone, setInvPhone] = useState("+977");
  const [invRole, setInvRole] = useState("manager");
  const [drvPhone, setDrvPhone] = useState("+977");
    const [rdrPhone, setRdrPhone] = useState("+977");
    const [rdrCap, setRdrCap] = useState("");
  const [topupAmt, setTopupAmt] = useState(5000);
  const [campCode, setCampCode] = useState("");
  const [campValue, setCampValue] = useState(10);
  const [confirm, setConfirm] = useState<null | "topup" | "payout">(null);
  const [busy, setBusy] = useState(false);

  const active = memberships.find((m) => m.partner_id === pid);
  const canManageMembers = active?.role === "owner" || active?.role === "admin";
  const canManageDrivers = canManageMembers || active?.role === "manager";
  const canManageMoney = canManageMembers || active?.role === "finance";
  const canManageCampaigns = canManageDrivers;

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
        const [mem, drv, an, wal, led, camp, rdr, vrf] = await Promise.all([
        api.partnerMembers(p),
        api.partnerDrivers(p),
        rides.partnerAnalytics(p),
        rides.partnerWallet(p),
        rides.partnerLedger(p),
        rides.partnerCampaigns(p),
          api.partnerRiders(p),
          rides.partnerVerifyLedger(p),
      ]);
      setMembers(mem);
      setDrivers(drv);
      setStats(an);
      setWallet(wal);
      setLedger(led);
      setCampaigns(camp);
        setRiders(rdr);
        setChainIntact(vrf.chain_intact);
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

    async function addRider() {
        if (!pid) return;
        try {
            await api.partnerAddRider(pid, {
                phone: rdrPhone.trim(),
                monthly_cap: rdrCap ? Number(rdrCap) : null,
            });
            setRdrPhone("+977");
            setRdrCap("");
            await loadFleet(pid);
        } catch (e) {
            setError((e as Error).message);
        }
    }

    async function releaseRider(riderUserId: string) {
        if (!pid) return;
        try {
            await api.partnerSetRiderStatus(pid, riderUserId, "left");
            await loadFleet(pid);
        } catch (e) {
            setError((e as Error).message);
        }
    }

  async function topup() {
    if (!pid) return;
    setBusy(true);
    try {
      const { reference } = await rides.partnerTopup(pid, Number(topupAmt));
      await rides.partnerConfirmTopup(pid, reference); // mock PSP callback
      await loadFleet(pid);
      setConfirm(null);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function payout() {
    if (!pid) return;
    setBusy(true);
    try {
      await rides.partnerRequestPayout(pid);
      await loadFleet(pid);
      setConfirm(null);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function createCampaign() {
    if (!pid || !campCode.trim()) return;
    try {
      await rides.partnerCreateCampaign(pid, {
        code: campCode.trim().toUpperCase(),
        title: `Fleet bonus ${campCode.trim().toUpperCase()}`,
        kind: "flat",
        value: Number(campValue),
      });
      setCampCode("");
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
        <>
          <div className="stat-grid">
            <Kpi
              label="Active drivers"
              value={String(stats.active_drivers)}
              hint={`${stats.trips.completed} trips completed`}
              icon={<Car size={16} />}
            />
            <Kpi
              label="Fleet GMV"
              value={`NPR ${Number(stats.money.gmv).toLocaleString()}`}
              hint="gross value of fleet trips"
              icon={<Banknote size={16} />}
            />
            <Kpi
              label="Driver earnings"
              value={`NPR ${Number(stats.money.driver_earnings).toLocaleString()}`}
              hint="paid to your drivers"
              icon={<TrendingUp size={16} />}
            />
            {wallet && (
              <Kpi
                label="Wallet balance"
                value={`NPR ${Number(wallet.balance).toLocaleString()}`}
                hint={`NPR ${Number(wallet.lifetime_share).toLocaleString()} lifetime share`}
                spark={ledger
                  .slice(0, 12)
                  .map((l) => Number(l.balance_after))
                  .reverse()}
                sparkColor="var(--color-green)"
                icon={<Wallet size={16} />}
              />
            )}
          </div>

          <div className="grid-2">
            <div className="card">
              <h3 style={{ marginTop: 0 }}>Trip outcomes</h3>
              <div className="row" style={{ gap: 20, justifyContent: "center" }}>
                <Donut
                  centerLabel={`${stats.trips.total}`}
                  centerSub="trips"
                  segments={[
                    { label: "Completed", value: stats.trips.completed, color: "var(--color-green)" },
                    { label: "Cancelled", value: stats.trips.cancelled, color: "var(--color-red)" },
                  ]}
                />
                <div className="stack" style={{ gap: 8 }}>
                  <Legend color="var(--color-green)" label="Completed" value={stats.trips.completed} />
                  <Legend color="var(--color-red)" label="Cancelled" value={stats.trips.cancelled} />
                </div>
              </div>
            </div>

            <div className="card">
              <h3 style={{ marginTop: 0 }}>Top drivers by earnings</h3>
              {stats.leaderboard.length > 0 ? (
                <BarChart
                  data={stats.leaderboard.slice(0, 6).map((d) => ({
                    label: (d.name ?? d.driver_id).slice(0, 8),
                    value: Number(d.earnings),
                  }))}
                  color="var(--color-brand)"
                  fmt={(v) => (v >= 1000 ? `${(v / 1000).toFixed(1)}k` : String(Math.round(v)))}
                />
              ) : (
                <div className="chart-empty" style={{ height: 190 }}>
                  No completed trips yet
                </div>
              )}
            </div>
          </div>
        </>
      )}

      {wallet && (
        <div className="card">
          <h3 style={{ marginTop: 0 }}>
            Finance{" "}
            {chainIntact !== null && (
              <span className={`badge ${chainIntact ? "ok" : "danger"}`} style={{ marginLeft: 8 }}>
                {chainIntact ? "ledger intact" : "ledger TAMPERED"}
              </span>
            )}
          </h3>
          <div className="stat-grid" style={{ marginBottom: 12 }}>
            <Stat label="Wallet balance" value={`NPR ${Number(wallet.balance).toLocaleString()}`} />
            <Stat label="Lifetime revenue share" value={`NPR ${Number(wallet.lifetime_share).toLocaleString()}`} />
          </div>
          {canManageMoney && (
            <div className="row" style={{ marginBottom: 12, flexWrap: "wrap" }}>
              <input className="input" style={{ maxWidth: 160 }} type="number" value={topupAmt} onChange={(e) => setTopupAmt(Number(e.target.value))} />
              <button className="btn primary" onClick={() => setConfirm("topup")}>
                Top up wallet
              </button>
              <button className="btn ghost" onClick={() => setConfirm("payout")}>
                Withdraw balance
              </button>
            </div>
          )}
          <table>
            <thead>
              <tr>
                <th>Type</th>
                <th>Amount</th>
                <th>Balance</th>
                <th>When</th>
              </tr>
            </thead>
            <tbody>
              {ledger.map((l, i) => (
                <tr key={i}>
                  <td className="subtle">{l.kind}</td>
                  <td>NPR {Number(l.amount).toLocaleString()}</td>
                  <td>NPR {Number(l.balance_after).toLocaleString()}</td>
                  <td className="subtle">{new Date(l.created_at).toLocaleString()}</td>
                </tr>
              ))}
              {ledger.length === 0 && (
                <tr>
                  <td colSpan={4} className="subtle" style={{ textAlign: "center" }}>
                    No movements yet — earn a share when your drivers complete trips.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      )}

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Fleet bonus campaigns</h3>
        <p className="subtle" style={{ marginTop: 0 }}>
          Partner-funded driver bonuses, paid from your wallet on trip completion.
        </p>
        {canManageCampaigns && (
          <div className="row" style={{ marginBottom: 12 }}>
            <input className="input" style={{ maxWidth: 180 }} value={campCode} onChange={(e) => setCampCode(e.target.value.toUpperCase())} placeholder="CODE" />
            <input className="input" style={{ maxWidth: 140 }} type="number" value={campValue} onChange={(e) => setCampValue(Number(e.target.value))} placeholder="NPR bonus" />
            <button className="btn primary" onClick={createCampaign}>
              Create bonus
            </button>
          </div>
        )}
        <table>
          <thead>
            <tr>
              <th>Code</th>
              <th>Bonus</th>
              <th>Used</th>
              <th>Status</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {campaigns.map((c) => (
              <tr key={c.id}>
                <td>
                  <b>{c.code}</b>
                </td>
                <td>{c.kind === "percent" ? `${c.value}%` : `NPR ${c.value}`}</td>
                <td className="subtle">{c.used_count}</td>
                <td>
                  <span className={`badge ${c.active ? "approved" : "rejected"}`}>{c.active ? "active" : "off"}</span>
                </td>
                <td style={{ textAlign: "right" }}>
                  {canManageCampaigns && c.active && (
                    <button className="btn ghost" onClick={() => rides.partnerDeactivateCampaign(pid!, c.id).then(() => loadFleet(pid!))}>
                      Stop
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {campaigns.length === 0 && (
              <tr>
                <td colSpan={5} className="subtle" style={{ textAlign: "center" }}>
                  No fleet campaigns yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

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
        <h3 style={{ marginTop: 0 }}>Corporate riders</h3>
        <p className="subtle" style={{ marginTop: 0 }}>
          Riders whose trips are billed to your wallet (ride-on-company-tab), with an optional
          monthly cap.
        </p>
        {canManageDrivers && (
          <div className="row" style={{ marginBottom: 12 }}>
            <input className="input" style={{ maxWidth: 220 }} value={rdrPhone} onChange={(e) => setRdrPhone(e.target.value)} placeholder="rider phone +977…" />
            <input className="input" style={{ maxWidth: 160 }} type="number" value={rdrCap} onChange={(e) => setRdrCap(e.target.value)} placeholder="monthly cap (opt)" />
            <button className="btn primary" onClick={addRider}>
              Add rider
            </button>
          </div>
        )}
        <table>
          <thead>
            <tr>
              <th>Phone</th>
              <th>Name</th>
              <th>Monthly cap</th>
              <th>Status</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {riders.map((r) => (
              <tr key={r.rider_user_id}>
                <td>{r.phone}</td>
                <td>{r.full_name ?? "—"}</td>
                <td className="subtle">{r.monthly_cap ? `NPR ${Number(r.monthly_cap).toLocaleString()}` : "unlimited"}</td>
                <td className="subtle">{r.status}</td>
                <td style={{ textAlign: "right" }}>
                  {canManageDrivers && r.status !== "left" && (
                    <button className="btn ghost" onClick={() => releaseRider(r.rider_user_id)}>
                      Remove
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {riders.length === 0 && (
              <tr>
                <td colSpan={5} className="subtle" style={{ textAlign: "center" }}>
                  No corporate riders yet.
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

      <ConfirmModal
        open={confirm === "topup"}
        onClose={() => setConfirm(null)}
        onConfirm={topup}
        title="Top up wallet"
        message={`Add NPR ${Number(topupAmt).toLocaleString()} to your fleet wallet? This simulates a payment-gateway top-up.`}
        confirmLabel="Top up"
        busy={busy}
      />
      <ConfirmModal
        open={confirm === "payout"}
        onClose={() => setConfirm(null)}
        onConfirm={payout}
        title="Withdraw balance"
        message={
          wallet
            ? `Withdraw the full wallet balance of NPR ${Number(wallet.balance).toLocaleString()} to your registered bank account?`
            : "Withdraw the full wallet balance to your registered bank account?"
        }
        confirmLabel="Withdraw"
        busy={busy}
      />
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

function Legend({ color, label, value }: { color: string; label: string; value: number }) {
  return (
    <div className="row" style={{ gap: 8 }}>
      <span className="status-dot" style={{ background: color }} />
      <span className="subtle text-[12.5px]">{label}</span>
      <b className="text-[13px]">{value}</b>
    </div>
  );
}
