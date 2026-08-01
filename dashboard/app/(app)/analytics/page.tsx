"use client";

import { rides, type AnalyticsOverview, type TimeseriesPoint } from "@/lib/api";
import { useEffect, useState } from "react";

export default function AnalyticsPage() {
  const [ov, setOv] = useState<AnalyticsOverview | null>(null);
  const [series, setSeries] = useState<TimeseriesPoint[]>([]);
  const [error, setError] = useState<string | null>(null);

  async function load() {
    setError(null);
    try {
      const [o, ts] = await Promise.all([
        rides.analyticsOverview(),
        rides.analyticsTimeseries(14),
      ]);
      setOv(o);
      setSeries(ts.series);
    } catch (e) {
      setError((e as Error).message);
    }
  }

  useEffect(() => {
    load();
  }, []);

  const pct = (n: number) => `${(n * 100).toFixed(1)}%`;
  const npr = (s: string) => `NPR ${Number(s).toLocaleString()}`;
  const maxReq = Math.max(1, ...series.map((s) => s.requested));

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Analytics</h1>
        <p className="subtle">
          Platform effectiveness at a glance — funnel, money, supply and demand. Updated live.
        </p>
      </div>

      {error && <div className="error">{error}</div>}

      {ov && (
        <>
          <h3 style={{ margin: "4px 0" }}>Trips</h3>
          <div className="stat-grid">
            <Stat label="Total trips" value={ov.trips.total} />
            <Stat label="Completed" value={ov.trips.completed} />
            <Stat label="Cancelled" value={ov.trips.cancelled} />
            <Stat label="In progress" value={ov.trips.active} />
            <Stat label="Completed today" value={ov.trips.completed_today} />
            <Stat label="Completion rate" value={pct(ov.trips.completion_rate)} />
            <Stat label="Cancellation rate" value={pct(ov.trips.cancellation_rate)} />
          </div>

          <h3 style={{ margin: "4px 0" }}>Money (completed)</h3>
          <div className="stat-grid">
            <Stat label="GMV" value={npr(ov.money.gmv)} />
            <Stat label="Commission earned" value={npr(ov.money.commission_earned)} />
            <Stat label="Accident fund (1%)" value={npr(ov.money.accident_fund_levied)} />
            <Stat label="Driver payouts" value={npr(ov.money.driver_payouts)} />
          </div>

          <h3 style={{ margin: "4px 0" }}>Tax posture</h3>
          <div className="stat-grid">
            <Stat label={`VAT on commission (${pct(Number(ov.tax.vat_rate))})`} value={npr(ov.tax.vat_on_commission)} />
            <Stat label="TDS withheld (payouts)" value={npr(ov.tax.tds_withheld)} />
          </div>

          <h3 style={{ margin: "4px 0" }}>Supply &amp; demand</h3>
          <div className="stat-grid">
            <Stat label="Drivers online" value={ov.supply.drivers_online} />
            <Stat label="Drivers approved" value={ov.supply.drivers_approved} />
            <Stat label="Drivers total" value={ov.supply.drivers_total} />
            <Stat label="Riders" value={ov.demand.riders} />
            <Stat label="Users total" value={ov.demand.users_total} />
            <Stat label="Signups (7d)" value={ov.demand.signups_7d} />
          </div>
        </>
      )}

      <h3 style={{ margin: "4px 0" }}>Last 14 days</h3>
      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Day</th>
              <th>Requested</th>
              <th>Completed</th>
              <th>GMV</th>
              <th style={{ width: "40%" }}>Volume</th>
            </tr>
          </thead>
          <tbody>
            {series.map((s) => (
              <tr key={s.day}>
                <td>{s.day}</td>
                <td>{s.requested}</td>
                <td>{s.completed}</td>
                <td>{npr(s.gmv)}</td>
                <td>
                  <div
                    style={{
                      height: 8,
                      borderRadius: 4,
                      background: "var(--brand)",
                      width: `${(s.requested / maxReq) * 100}%`,
                      minWidth: s.requested > 0 ? 4 : 0,
                    }}
                  />
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
