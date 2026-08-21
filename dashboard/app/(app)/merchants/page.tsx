"use client";

import { Pagination, SearchInput, Segmented, usePaged } from "@/components/Toolbar";
import { merchant, type MerchantRow, type NewMerchant } from "@/lib/api";
import { useRouter } from "next/navigation";
import { useEffect, useMemo, useState } from "react";

const VERTICALS = [
  { key: "all", label: "All" },
  { key: "food", label: "Food" },
  { key: "grocery", label: "Grocery" },
];

const EMPTY: NewMerchant = {
  name: "",
  vertical: "food",
  lat: 28.033,
  lng: 82.484,
  address: "",
  phone: "",
};

export default function MerchantsPage() {
  const router = useRouter();
  const [rows, setRows] = useState<MerchantRow[]>([]);
  const [vertical, setVertical] = useState("all");
  const [query, setQuery] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [form, setForm] = useState<NewMerchant>(EMPTY);
  const [busy, setBusy] = useState(false);

  async function load() {
    setError(null);
    setLoading(true);
    try {
      setRows(await merchant.list());
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    load();
  }, []);

  const filtered = useMemo(() => {
    let list = rows;
    if (vertical !== "all") list = list.filter((m) => m.vertical === vertical);
    const q = query.trim().toLowerCase();
    if (q) {
      list = list.filter((m) =>
        [m.name, m.phone, m.address].filter(Boolean).some((v) => String(v).toLowerCase().includes(q)),
      );
    }
    return list;
  }, [rows, vertical, query]);

  const { page, setPage, pageCount, total, slice } = usePaged(filtered, 12);

  function set<K extends keyof NewMerchant>(key: K, value: NewMerchant[K]) {
    setForm((f) => ({ ...f, [key]: value }));
  }

  async function create() {
    setBusy(true);
    setError(null);
    try {
      await merchant.create({
        ...form,
        address: form.address || null,
        phone: form.phone || null,
      });
      setForm(EMPTY);
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
        <h1 className="page-title">Merchants</h1>
        <p className="subtle">
          Stores on the food/grocery marketplace. New self-serve applications start closed —
          the owner opens the store once their menu is ready.
        </p>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="card">
        <h3 style={{ marginTop: 0 }}>Onboard a merchant</h3>
        <div className="grid-2">
          <div className="field">
            <label>Store name</label>
            <input className="input" value={form.name} onChange={(e) => set("name", e.target.value)} placeholder="Ghorahi Momo House" />
          </div>
          <div className="field">
            <label>Vertical</label>
            <select className="input" value={form.vertical} onChange={(e) => set("vertical", e.target.value)}>
              <option value="food">Food</option>
              <option value="grocery">Grocery</option>
            </select>
          </div>
          <div className="field">
            <label>Phone</label>
            <input className="input" value={form.phone ?? ""} onChange={(e) => set("phone", e.target.value)} placeholder="+9779800000000" />
          </div>
          <div className="field">
            <label>Address</label>
            <input className="input" value={form.address ?? ""} onChange={(e) => set("address", e.target.value)} placeholder="Tribhuvan Chowk, Ghorahi" />
          </div>
          <div className="field">
            <label>Latitude</label>
            <input
              className="input"
              type="number"
              step="0.0001"
              value={form.lat}
              onChange={(e) => set("lat", Number(e.target.value))}
            />
          </div>
          <div className="field">
            <label>Longitude</label>
            <input
              className="input"
              type="number"
              step="0.0001"
              value={form.lng}
              onChange={(e) => set("lng", Number(e.target.value))}
            />
          </div>
        </div>
        <button className="btn primary" disabled={busy || !form.name} onClick={create}>
          {busy ? "Creating…" : "Create merchant"}
        </button>
      </div>

      <div className="toolbar">
        <Segmented
          options={VERTICALS}
          value={vertical}
          onChange={(k) => {
            setVertical(k);
            setPage(0);
          }}
        />
        <div className="toolbar-actions">
          <SearchInput value={query} onChange={setQuery} placeholder="Name, phone, address…" />
        </div>
      </div>

      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Name</th>
              <th>Vertical</th>
              <th>Phone</th>
              <th>Rating</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            {slice.map((m) => (
              <tr key={m.id} onClick={() => router.push(`/merchants/${m.id}`)}>
                <td>
                  <b>{m.name}</b>
                  <div className="subtle" style={{ fontSize: 13 }}>{m.address ?? "—"}</div>
                </td>
                <td className="subtle">{m.vertical}</td>
                <td className="subtle">{m.phone ?? "—"}</td>
                <td className="subtle">{Number(m.rating).toFixed(1)}</td>
                <td>
                  <span className={`badge ${m.is_open ? "approved" : "pending"}`}>
                    {m.is_open ? "open" : "closed"}
                  </span>
                </td>
              </tr>
            ))}
            {!loading && filtered.length === 0 && (
              <tr>
                <td colSpan={5} className="subtle" style={{ textAlign: "center", padding: 32 }}>
                  No merchants yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <Pagination page={page} pageCount={pageCount} total={total} onPage={setPage} />
    </div>
  );
}
