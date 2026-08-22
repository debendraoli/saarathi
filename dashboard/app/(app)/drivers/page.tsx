"use client";

import { OnsiteKycModal } from "@/components/OnsiteKycModal";
import { Pagination, SearchInput, Segmented, usePaged } from "@/components/Toolbar";
import { api, type DriverListItem } from "@/lib/api";
import { Plus } from "lucide-react";
import { useRouter } from "next/navigation";
import { useEffect, useMemo, useState } from "react";

// Approved drivers are done — nothing left to review — so they're not worth
// a tab here. If you need to look one up, the queue's search covers active
// drivers; a dedicated "all drivers" view can come later if that's needed.
const TABS = [
  { key: "queue", label: "Review queue" },
  { key: "rejected", label: "Rejected" },
];

export default function DriversPage() {
  const router = useRouter();
  const [tab, setTab] = useState("queue");
  const [rows, setRows] = useState<DriverListItem[]>([]);
  const [query, setQuery] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [showOnsite, setShowOnsite] = useState(false);

  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError(null);
    api
      .listDrivers(tab)
      .then((data) => active && setRows(data))
      .catch((e) => active && setError((e as Error).message))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [tab, reloadKey]);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter((d) =>
      [d.full_name, d.phone, d.license_number]
        .filter(Boolean)
        .some((v) => String(v).toLowerCase().includes(q)),
    );
  }, [rows, query]);

  const { page, setPage, pageCount, total, slice } = usePaged(filtered, 12);

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Driver KYC</h1>
        <p className="subtle">Review KYC submissions and approve or reject drivers.</p>
      </div>

      <div className="toolbar">
        <Segmented
          options={TABS}
          value={tab}
          onChange={(k) => {
            setTab(k);
            setPage(0);
          }}
        />
        <div className="toolbar-actions">
          <SearchInput value={query} onChange={setQuery} placeholder="Name, phone, license…" />
          <button className="btn primary" onClick={() => setShowOnsite(true)}>
            <Plus size={15} /> On-site KYC
          </button>
        </div>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Name</th>
              <th>Phone</th>
              <th>License</th>
              <th>Status</th>
              <th>Submitted</th>
            </tr>
          </thead>
          <tbody>
            {slice.map((d) => (
              <tr key={d.id} onClick={() => router.push(`/drivers/${d.id}`)}>
                <td>{d.full_name ?? "—"}</td>
                <td>{d.phone}</td>
                <td>{d.license_number ?? "—"}</td>
                <td>
                  <span className={`badge ${d.kyc_status}`}>{label(d.kyc_status)}</span>
                </td>
                <td className="subtle">{fmtDate(d.created_at)}</td>
              </tr>
            ))}
            {!loading && filtered.length === 0 && (
              <tr>
                <td colSpan={5} className="subtle" style={{ textAlign: "center", padding: 32 }}>
                  Nothing here.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <Pagination page={page} pageCount={pageCount} total={total} onPage={setPage} />

      <OnsiteKycModal
        open={showOnsite}
        onClose={() => setShowOnsite(false)}
        onCreated={() => setReloadKey((k) => k + 1)}
      />
    </div>
  );
}

function label(s: string) {
  return s.replace("_", " ");
}

function fmtDate(iso: string) {
  return new Date(iso).toLocaleString();
}
