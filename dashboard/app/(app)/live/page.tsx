"use client";

import { TripMap } from "@/components/TripMap";
import { rides, type ActiveTrip, type TripLocation } from "@/lib/api";
import { useEffect, useState } from "react";

export default function LivePage() {
  const [trips, setTrips] = useState<ActiveTrip[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [loc, setLoc] = useState<TripLocation | null>(null);
  const [error, setError] = useState<string | null>(null);
  const selectedTrip = trips.find((t) => t.id === selected) ?? null;

  async function load() {
    setError(null);
    try {
      setTrips(await rides.activeTrips());
    } catch (e) {
      setError((e as Error).message);
    }
  }

  useEffect(() => {
    load();
    const t = setInterval(load, 5000);
    return () => clearInterval(t);
  }, []);

  useEffect(() => {
    if (!selected) return;
    let active = true;
    const poll = async () => {
      try {
        const l = await rides.tripLocation(selected);
        if (active) setLoc(l);
      } catch {
        if (active) setLoc(null);
      }
    };
    poll();
    const t = setInterval(poll, 3000);
    return () => {
      active = false;
      clearInterval(t);
    };
  }, [selected]);

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Live Tracking</h1>
        <p className="subtle">Trips in progress. Click one to follow the driver&apos;s position.</p>
      </div>
      {error && <div className="error">{error}</div>}
      <div className="grid-2">
        <div className="card" style={{ padding: 0 }}>
          <table>
            <thead>
              <tr>
                <th>Trip</th>
                <th>Status</th>
                <th>Fare</th>
              </tr>
            </thead>
            <tbody>
              {trips.map((t) => (
                <tr key={t.id} onClick={() => setSelected(t.id)}>
                  <td>{t.id.slice(0, 8)}…</td>
                  <td>
                    <span className={`badge ${t.status === "in_progress" ? "approved" : "under_review"}`}>
                      {t.status.replace("_", " ")}
                    </span>
                  </td>
                  <td className="subtle">NPR {t.final_fare}</td>
                </tr>
              ))}
              {trips.length === 0 && (
                <tr>
                  <td colSpan={3} className="subtle" style={{ textAlign: "center", padding: 24 }}>
                    No active trips.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
        <div className="card">
          <h3 style={{ marginTop: 0 }}>Driver position</h3>
          {!selected || !selectedTrip ? (
            <p className="subtle">Select a trip.</p>
          ) : loc && loc.lat != null && loc.lng != null ? (
            <>
              <TripMap
                origin={{ lat: selectedTrip.origin_lat, lng: selectedTrip.origin_lng }}
                dest={{ lat: selectedTrip.dest_lat, lng: selectedTrip.dest_lng }}
                live={{ lat: loc.lat, lng: loc.lng }}
                heightPx={280}
              />
              <dl className="kv" style={{ marginTop: 12 }}>
                <dt>Heading</dt>
                <dd>{loc.heading ?? "—"}°</dd>
                <dt>Speed</dt>
                <dd>{loc.speed ?? "—"} m/s</dd>
                <dt>Updated</dt>
                <dd>{loc.at ? new Date(loc.at * 1000).toLocaleTimeString() : "—"}</dd>
              </dl>
            </>
          ) : (
            <p className="subtle">Waiting for a location ping…</p>
          )}
        </div>
      </div>
    </div>
  );
}
