"use client";

import { Pagination, SearchInput, usePaged } from "@/components/Toolbar";
import { rides, type DriverDirectoryRow } from "@/lib/api";
import { useRouter } from "next/navigation";
import { Suspense, useEffect, useState } from "react";

export default function AllDriversPage() {
  return (
    <Suspense fallback={null}>
      <AllDriversPageInner />
    </Suspense>
  );
}

function AllDriversPageInner() {
  const router = useRouter();
  const [rows, setRows] = useState<DriverDirectoryRow[]>([]);
  const [query, setQuery] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError(null);
    const t = setTimeout(() => {
      rides
        .driverDirectory(query)
        .then((data) => active && setRows(data))
        .catch((e) => active && setError((e as Error).message))
        .finally(() => active && setLoading(false));
    }, 250); // debounce — search is server-side
    return () => {
      active = false;
      clearTimeout(t);
    };
  }, [query]);

  const { page, setPage, pageCount, total, slice } = usePaged(rows, 15);

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Drivers</h1>
        <p className="subtle">Every driver regardless of KYC status, with lifetime trips and earnings.</p>
      </div>

      <div className="toolbar">
        <div />
        <div className="toolbar-actions">
          <SearchInput
            value={query}
            onChange={(v) => {
              setQuery(v);
              setPage(0);
            }}
            placeholder="Name or phone…"
          />
        </div>
      </div>

      {error && <div className="error">{error}</div>}

      <div className="card" style={{ padding: 0 }}>
        <table>
          <thead>
            <tr>
              <th>Name</th>
              <th>Phone</th>
              <th>KYC</th>
              <th>Joined</th>
              <th>Trips</th>
              <th>Earnings</th>
            </tr>
          </thead>
          <tbody>
            {slice.map((r) => (
              <tr key={r.driver_id} onClick={() => router.push(`/drivers/${r.driver_id}?from=all`)}>
                <td><b>{r.full_name ?? "—"}</b></td>
                <td>{r.phone}</td>
                <td>
                  <span className={`badge ${r.kyc_status}`}>{r.kyc_status.replace("_", " ")}</span>
                </td>
                <td className="subtle">{new Date(r.created_at).toLocaleDateString()}</td>
                <td>{r.total_trips}</td>
                <td>NPR {r.total_earnings}</td>
              </tr>
            ))}
            {!loading && rows.length === 0 && (
              <tr>
                <td colSpan={6} className="subtle" style={{ textAlign: "center", padding: 32 }}>
                  No drivers found.
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
