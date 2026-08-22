"use client";

import { Pagination, SearchInput, usePaged } from "@/components/Toolbar";
import { rides, type RiderRow } from "@/lib/api";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";

export default function UsersPage() {
  const router = useRouter();
  const [rows, setRows] = useState<RiderRow[]>([]);
  const [query, setQuery] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError(null);
    const t = setTimeout(() => {
      rides
        .riders(query)
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
        <h1 className="page-title">Users</h1>
        <p className="subtle">Every registered account, with lifetime trips and spend.</p>
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
              <th>Status</th>
              <th>Joined</th>
              <th>Rides</th>
              <th>Spend</th>
            </tr>
          </thead>
          <tbody>
            {slice.map((r) => (
              <tr key={r.id} onClick={() => router.push(`/users/${r.id}`)}>
                <td><b>{r.full_name ?? "—"}</b></td>
                <td>{r.phone}</td>
                <td>
                  <span className={`badge ${r.status === "active" ? "approved" : "rejected"}`}>
                    {r.status}
                  </span>
                </td>
                <td className="subtle">{new Date(r.created_at).toLocaleDateString()}</td>
                <td>{r.total_rides}</td>
                <td>NPR {r.total_spend}</td>
              </tr>
            ))}
            {!loading && rows.length === 0 && (
              <tr>
                <td colSpan={6} className="subtle" style={{ textAlign: "center", padding: 32 }}>
                  No users found.
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
