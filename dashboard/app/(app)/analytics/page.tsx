"use client";

import { BarChart, Donut, Kpi, LineChart } from "@/components/Charts";
import { rides, type AnalyticsOverview, type TimeseriesPoint } from "@/lib/api";
import { Banknote, TrendingUp, UserCheck, Users } from "lucide-react";
import { useEffect, useState } from "react";

export default function AnalyticsPage() {
  const [ov, setOv] = useState<AnalyticsOverview | null>(null);
  const [series, setSeries] = useState<TimeseriesPoint[]>([]);
  const [error, setError] = useState<string | null>(null);

  async function load() {
    setError(null);
    try {
      const [o, ts] = await Promise.all([rides.analyticsOverview(), rides.analyticsTimeseries(14)]);
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
  const npr = (s: string | number) => `NPR ${Number(s).toLocaleString()}`;
  const kNpr = (s: number) => (s >= 1000 ? `${(s / 1000).toFixed(1)}k` : String(Math.round(s)));

  const gmvSeries = series.map((s) => ({ label: s.day.slice(5), value: Number(s.gmv) }));
  const reqSpark = series.map((s) => s.requested);
  const gmvSpark = series.map((s) => Number(s.gmv));

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Analytics</h1>
        <p className="subtle">
          Platform effectiveness at a glance — funnel, money, supply and demand.
        </p>
      </div>

      {error && <div className="error">{error}</div>}

      {ov && (
        <>
          <div className="stat-grid">
            <Kpi
              label="GMV (completed)"
              value={npr(ov.money.gmv)}
              hint="lifetime"
              spark={gmvSpark}
              sparkColor="var(--color-brand)"
              icon={<Banknote size={16} />}
            />
            <Kpi
              label="Completion rate"
              value={pct(ov.trips.completion_rate)}
              hint={`${ov.trips.completed} of ${ov.trips.total} trips`}
              icon={<TrendingUp size={16} />}
            />
            <Kpi
              label="Drivers online"
              value={String(ov.supply.drivers_online)}
              hint={`${ov.supply.drivers_approved} approved`}
              icon={<UserCheck size={16} />}
            />
            <Kpi
              label="Signups (7d)"
              value={String(ov.demand.signups_7d)}
              hint={`${ov.demand.users_total} users total`}
              spark={reqSpark}
              sparkColor="var(--color-blue)"
              icon={<Users size={16} />}
            />
          </div>

          <div className="grid-2">
            <div className="card">
              <h3>Trip volume · last 14 days</h3>
              <p className="subtle text-[12.5px]" style={{ marginTop: 2, marginBottom: 8 }}>
                Requested vs. completed
              </p>
              <LineChart
                data={series as unknown as Record<string, number | string>[]}
                x="day"
                series={[
                  { key: "requested", label: "Requested", color: "var(--color-blue)" },
                  { key: "completed", label: "Completed", color: "var(--color-brand)" },
                ]}
              />
            </div>

            <div className="card">
              <h3>Trip outcomes</h3>
              <p className="subtle text-[12.5px]" style={{ marginTop: 2, marginBottom: 8 }}>
                Share of all trips
              </p>
              <div className="row" style={{ gap: 20, justifyContent: "center" }}>
                <Donut
                  centerLabel={pct(ov.trips.completion_rate)}
                  segments={[
                    { label: "Completed", value: ov.trips.completed, color: "var(--color-green)" },
                    { label: "Cancelled", value: ov.trips.cancelled, color: "var(--color-red)" },
                    { label: "Active", value: ov.trips.active, color: "var(--color-blue)" },
                  ]}
                />
                <div className="stack" style={{ gap: 8 }}>
                  <Legend color="var(--color-green)" label="Completed" value={ov.trips.completed} />
                  <Legend color="var(--color-red)" label="Cancelled" value={ov.trips.cancelled} />
                  <Legend color="var(--color-blue)" label="Active" value={ov.trips.active} />
                </div>
              </div>
            </div>
          </div>

          <div className="card">
            <h3>GMV · last 14 days</h3>
            <BarChart data={gmvSeries} color="var(--color-brand)" fmt={kNpr} />
          </div>

          <h3 style={{ margin: "4px 0" }}>Money (completed)</h3>
          <div className="stat-grid">
            <Stat label="GMV" value={npr(ov.money.gmv)} />
            <Stat label="Commission earned" value={npr(ov.money.commission_earned)} />
            <Stat label="Accident fund (1%)" value={npr(ov.money.accident_fund_levied)} />
            <Stat label="Driver payouts" value={npr(ov.money.driver_payouts)} />
            <Stat
              label={`VAT on commission (${pct(Number(ov.tax.vat_rate))})`}
              value={npr(ov.tax.vat_on_commission)}
            />
            <Stat label="TDS withheld" value={npr(ov.tax.tds_withheld)} />
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
