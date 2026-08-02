"use client";

import { RefreshCw } from "lucide-react";
import { useCallback, useEffect, useState } from "react";

const BASE = process.env.NEXT_PUBLIC_API_BASE ?? "http://localhost:8080";

const SERVICES = [
  { key: "auth", label: "Auth & Identity", port: 8081 },
  { key: "rides", label: "Rides & Delivery", port: 8082 },
  { key: "notify", label: "Notifications", port: 8083 },
  { key: "routing", label: "Routing (internal)", port: 8084 },
  { key: "payments", label: "Payments", port: 8085 },
  { key: "campaigns", label: "Campaigns", port: 8086 },
  { key: "partners", label: "Partners / Fleet", port: 8087 },
];

type State = "checking" | "up" | "down";
type Result = { state: State; latency?: number };

export default function HealthPage() {
  const [results, setResults] = useState<Record<string, Result>>({});
  const [checking, setChecking] = useState(false);
  const [lastChecked, setLastChecked] = useState<Date | null>(null);

  const check = useCallback(async () => {
    setChecking(true);
    await Promise.all(
      SERVICES.map(async (s) => {
        const t0 = performance.now();
        try {
          const res = await fetch(`${BASE}/status/${s.key}`, { cache: "no-store" });
          const j = await res.json().catch(() => ({}));
          const ok = res.ok && j?.status === "ok";
          setResults((r) => ({
            ...r,
            [s.key]: { state: ok ? "up" : "down", latency: Math.round(performance.now() - t0) },
          }));
        } catch {
          setResults((r) => ({
            ...r,
            [s.key]: { state: "down", latency: Math.round(performance.now() - t0) },
          }));
        }
      }),
    );
    setChecking(false);
    setLastChecked(new Date());
  }, []);

  useEffect(() => {
    check();
    const id = setInterval(check, 15000);
    return () => clearInterval(id);
  }, [check]);

  const up = SERVICES.filter((s) => results[s.key]?.state === "up").length;
  const allUp = up === SERVICES.length;

  return (
    <div className="stack">
      <div className="toolbar">
        <div>
          <div className="page-title">Services health</div>
          <div className="subtle">
            {up}/{SERVICES.length} healthy
            {lastChecked ? ` · checked ${lastChecked.toLocaleTimeString()}` : ""}
          </div>
        </div>
        <button className="btn" onClick={check} disabled={checking}>
          <RefreshCw size={15} /> {checking ? "Checking…" : "Refresh"}
        </button>
      </div>

      <div className={allUp ? "notice" : "error"}>
        {allUp
          ? "All services are responding through the API gateway."
          : `${SERVICES.length - up} service(s) not responding — traffic through the gateway may degrade.`}
      </div>

      <div className="health-grid">
        {SERVICES.map((s) => {
          const state = results[s.key]?.state ?? "checking";
          const latency = results[s.key]?.latency;
          return (
            <div key={s.key} className="health-card">
              <div>
                <div className="row" style={{ gap: 8 }}>
                  <span className={`status-dot ${state}`} />
                  <b>{s.label}</b>
                </div>
                <div className="subtle text-[12px]" style={{ marginTop: 4 }}>
                  :{s.port} · {latency != null ? `${latency}ms` : "…"}
                </div>
              </div>
              <span
                className={`badge ${state === "up" ? "ok" : state === "down" ? "danger" : "submitted"}`}
              >
                {state === "up" ? "up" : state === "down" ? "down" : "…"}
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}
