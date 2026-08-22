"use client";

import { TopupModal } from "@/components/TopupModal";
import { auth, rides, type RiderDetail } from "@/lib/api";
import Link from "next/link";
import { use, useEffect, useState } from "react";

export default function RiderDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const [data, setData] = useState<RiderDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [showTopup, setShowTopup] = useState(false);
  const canTopup = ["super_admin", "admin"].includes(auth.user?.role ?? "");

  async function load() {
    setError(null);
    try {
      setData(await rides.riderDetail(id));
    } catch (e) {
      setError((e as Error).message);
    }
  }

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  if (!data) {
    return (
      <div className="stack">
        <Link href="/users" className="muted-link">← Back to users</Link>
        {error ? <div className="error">{error}</div> : <p className="subtle">Loading…</p>}
      </div>
    );
  }

  return (
    <div className="stack">
      <Link href="/users" className="muted-link">← Back to users</Link>

      <div className="row">
        <h1 className="page-title" style={{ margin: 0 }}>{data.full_name ?? data.phone}</h1>
        <span className={`badge ${data.status === "active" ? "approved" : "rejected"}`}>
          {data.status}
        </span>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="row">
        <div className="card">
          <dl className="kv">
            <dt>Phone</dt>
            <dd>{data.phone}</dd>
            <dt>Joined</dt>
            <dd>{new Date(data.created_at).toLocaleString()}</dd>
          </dl>
        </div>
        {canTopup && (
          <button className="btn primary" onClick={() => setShowTopup(true)}>
            Top up credits
          </button>
        )}
      </div>

      <div className="stat-grid">
        <div className="stat">
          <div className="label">Total rides</div>
          <div className="value">{data.total_rides}</div>
        </div>
        <div className="stat">
          <div className="label">Completed</div>
          <div className="value">{data.completed_rides}</div>
        </div>
        <div className="stat">
          <div className="label">Cancelled</div>
          <div className="value">{data.cancelled_rides}</div>
        </div>
        <div className="stat">
          <div className="label">Total spend</div>
          <div className="value">NPR {data.total_spend}</div>
        </div>
        <div className="stat">
          <div className="label">Rating (as passenger)</div>
          <div className="value">
            {data.avg_rating != null ? `${data.avg_rating.toFixed(1)} ★` : "—"}
          </div>
          {data.rating_count > 0 && (
            <div className="subtle" style={{ fontSize: 12.5 }}>{data.rating_count} ratings</div>
          )}
        </div>
      </div>

      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Driver</th>
              <th>Status</th>
              <th>Fare</th>
              <th>Pay</th>
              <th>Rating</th>
              <th>When</th>
            </tr>
          </thead>
          <tbody>
            {data.recent_trips.map((t) => (
              <tr key={t.id}>
                <td>{t.driver_name ?? (t.driver_id ? t.driver_id.slice(0, 8) : "—")}</td>
                <td>
                  <span className={`badge ${t.status === "completed" ? "approved" : t.status === "cancelled" ? "rejected" : "under_review"}`}>
                    {t.status.replace("_", " ")}
                  </span>
                </td>
                <td>NPR {t.final_fare}</td>
                <td className="subtle">{t.payment_method}</td>
                <td>{t.driver_stars ? "★".repeat(t.driver_stars) : "—"}</td>
                <td className="subtle">{new Date(t.created_at).toLocaleString()}</td>
              </tr>
            ))}
            {data.recent_trips.length === 0 && (
              <tr>
                <td colSpan={6} className="subtle" style={{ textAlign: "center", padding: 24 }}>
                  No trips yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <TopupModal
        open={showTopup}
        onClose={() => setShowTopup(false)}
        userId={data.id}
        kind="rider"
        onDone={() => load()}
      />
    </div>
  );
}
