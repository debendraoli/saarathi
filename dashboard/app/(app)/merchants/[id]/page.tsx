"use client";

import {
  merchant,
  type MerchantMenuItem,
  type MerchantOrderRow,
  type MerchantRow,
  type ZonePoint,
} from "@/lib/api";
import Link from "next/link";
import { use, useEffect, useState } from "react";

export default function MerchantDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const [row, setRow] = useState<MerchantRow | null>(null);
  const [menu, setMenu] = useState<MerchantMenuItem[]>([]);
  const [orders, setOrders] = useState<MerchantOrderRow[]>([]);
  const [points, setPoints] = useState<ZonePoint[]>([]);
  const [cellCount, setCellCount] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [zoneBusy, setZoneBusy] = useState(false);

  async function load() {
    setError(null);
    try {
      const [rows, items, allOrders, zone] = await Promise.all([
        merchant.list(),
        merchant.menu(id),
        merchant.orders(),
        merchant.zone(id).catch(() => null),
      ]);
      setRow(rows.find((m) => m.id === id) ?? null);
      setMenu(items);
      setOrders(allOrders.filter((o) => o.merchant_id === id));
      if (zone) {
        setPoints(zone.points);
        setCellCount(zone.cell_count);
      }
    } catch (e) {
      setError((e as Error).message);
    }
  }

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  async function toggleOpen() {
    if (!row) return;
    setBusy(true);
    setError(null);
    try {
      await merchant.setOpen(id, !row.is_open);
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  function setPoint(i: number, key: keyof ZonePoint, value: number) {
    setPoints((pts) => pts.map((p, idx) => (idx === i ? { ...p, [key]: value } : p)));
  }

  function addPoint() {
    const base = points[points.length - 1] ?? (row ? { lat: row.lat, lng: row.lng } : { lat: 28.033, lng: 82.484 });
    setPoints((pts) => [...pts, { ...base }]);
  }

  function removePoint(i: number) {
    setPoints((pts) => pts.filter((_, idx) => idx !== i));
  }

  async function saveZone() {
    if (points.length < 3) {
      setError("A zone needs at least 3 points.");
      return;
    }
    setZoneBusy(true);
    setError(null);
    try {
      const res = await merchant.setZone(id, points);
      setCellCount(res.cell_count);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setZoneBusy(false);
    }
  }

  if (!row) {
    return (
      <div className="stack">
        <Link href="/merchants" className="muted-link">← Back to merchants</Link>
        {error ? <div className="error">{error}</div> : <p className="subtle">Loading…</p>}
      </div>
    );
  }

  return (
    <div className="stack">
      <Link href="/merchants" className="muted-link">← Back to merchants</Link>

      <div className="row">
        <h1 className="page-title" style={{ margin: 0 }}>{row.name}</h1>
        <span className={`badge ${row.is_open ? "approved" : "pending"}`}>
          {row.is_open ? "open" : "closed"}
        </span>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="grid-2">
        <div className="card">
          <h3 style={{ marginTop: 0 }}>Store</h3>
          <dl className="kv">
            <dt>Vertical</dt>
            <dd>{row.vertical}</dd>
            <dt>Phone</dt>
            <dd>{row.phone ?? "—"}</dd>
            <dt>Address</dt>
            <dd>{row.address ?? "—"}</dd>
            <dt>Location</dt>
            <dd>
              <a
                className="muted-link"
                href={`https://www.openstreetmap.org/?mlat=${row.lat}&mlon=${row.lng}#map=17/${row.lat}/${row.lng}`}
                target="_blank"
                rel="noreferrer"
              >
                {row.lat.toFixed(5)}, {row.lng.toFixed(5)} ↗
              </a>
            </dd>
            <dt>Prep time</dt>
            <dd>{row.prep_mins} min</dd>
            <dt>Rating</dt>
            <dd>{Number(row.rating).toFixed(1)}</dd>
          </dl>
        </div>

        <div className="card">
          <h3 style={{ marginTop: 0 }}>Availability</h3>
          <p className="subtle">
            Staff override — closes or reopens the store regardless of what the owner has set.
          </p>
          <button className="btn primary" style={{ marginTop: 12 }} disabled={busy} onClick={toggleOpen}>
            {busy ? "Saving…" : row.is_open ? "Close store" : "Open store"}
          </button>
        </div>
      </div>

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Delivery zone</h3>
        <p className="subtle">
          {points.length === 0
            ? "No zone defined — the store is visible/deliverable everywhere."
            : `${points.length} points, ${cellCount} H3 cells cached.`}
        </p>
        <div className="doc-list">
          {points.map((p, i) => (
            <div className="row" key={i} style={{ gap: 8 }}>
              <input
                className="input"
                type="number"
                step="0.0001"
                value={p.lat}
                onChange={(e) => setPoint(i, "lat", Number(e.target.value))}
                style={{ maxWidth: 140 }}
              />
              <input
                className="input"
                type="number"
                step="0.0001"
                value={p.lng}
                onChange={(e) => setPoint(i, "lng", Number(e.target.value))}
                style={{ maxWidth: 140 }}
              />
              <button className="btn ghost" onClick={() => removePoint(i)}>Remove</button>
            </div>
          ))}
        </div>
        <div className="row" style={{ marginTop: 12 }}>
          <button className="btn ghost" onClick={addPoint}>+ Add point</button>
          <button className="btn primary" disabled={zoneBusy} onClick={saveZone}>
            {zoneBusy ? "Saving…" : "Save zone"}
          </button>
        </div>
      </div>

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Menu</h3>
        {menu.length === 0 ? (
          <p className="subtle">No items yet.</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Item</th>
                <th>Category</th>
                <th>Price</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {menu.map((it) => (
                <tr key={it.id}>
                  <td>{it.name}</td>
                  <td className="subtle">{it.category ?? "—"}</td>
                  <td>NPR {Number(it.price).toFixed(2)}</td>
                  <td>
                    <span className={`badge ${it.is_available ? "approved" : "pending"}`}>
                      {it.is_available ? "available" : "unavailable"}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Orders</h3>
        {orders.length === 0 ? (
          <p className="subtle">No orders yet.</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Order</th>
                <th>Status</th>
                <th>Total</th>
                <th>Payment</th>
                <th>Placed</th>
              </tr>
            </thead>
            <tbody>
              {orders.map((o) => (
                <tr key={o.id}>
                  <td>{o.id.slice(0, 8)}…</td>
                  <td>
                    <span className={`badge ${o.status === "delivered" ? "approved" : "under_review"}`}>
                      {o.status.replace("_", " ")}
                    </span>
                  </td>
                  <td>NPR {Number(o.total).toFixed(2)}</td>
                  <td className="subtle">{o.payment_method}</td>
                  <td className="subtle">{new Date(o.created_at).toLocaleString()}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
