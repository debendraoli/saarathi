"use client";

import { Pagination, SearchInput, Segmented, usePaged } from "@/components/Toolbar";
import { places, type PlaceContributionAdmin } from "@/lib/api";
import { useRouter } from "next/navigation";
import { useEffect, useMemo, useState } from "react";

const TABS = [
  { key: "pending", label: "Review queue" },
  { key: "approved", label: "Approved" },
  { key: "rejected", label: "Rejected" },
];

export default function PlacesPage() {
  const router = useRouter();
  const [tab, setTab] = useState("pending");
  const [rows, setRows] = useState<PlaceContributionAdmin[]>([]);
  const [query, setQuery] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError(null);
    places
      .queue(tab as "pending" | "approved" | "rejected")
      .then((data) => active && setRows(data))
      .catch((e) => active && setError((e as Error).message))
      .finally(() => active && setLoading(false));
    return () => {
      active = false;
    };
  }, [tab]);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter((r) => [r.name, r.category].some((v) => v.toLowerCase().includes(q)));
  }, [rows, query]);

  const { page, setPage, pageCount, total, slice } = usePaged(filtered, 12);

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Map Contributions</h1>
        <p className="subtle">Review community-submitted places and either approve or reject them.</p>
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
          <SearchInput value={query} onChange={setQuery} placeholder="Name, category…" />
        </div>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Name</th>
              <th>Category</th>
              <th>Capture distance</th>
              <th>Status</th>
              <th>Submitted</th>
            </tr>
          </thead>
          <tbody>
            {slice.map((r) => (
              <tr key={r.id} onClick={() => router.push(`/places/${r.id}`)}>
                <td>{r.name}</td>
                <td>{r.category.replace("_", " ")}</td>
                <td className="subtle">{Math.round(r.capture_distance_m)} m</td>
                <td>
                  <span className={`badge ${r.status}`}>{r.status}</span>
                </td>
                <td className="subtle">{fmtDate(r.created_at)}</td>
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
    </div>
  );
}

function fmtDate(iso: string) {
  return new Date(iso).toLocaleString();
}
