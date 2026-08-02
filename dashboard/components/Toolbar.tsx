"use client";

import { ChevronLeft, ChevronRight, Search } from "lucide-react";
import { useMemo, useState } from "react";

export function SearchInput({
  value,
  onChange,
  placeholder = "Search…",
}: {
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
}) {
  return (
    <div className="search">
      <Search size={15} className="search-icon" />
      <input
        className="search-input"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder={placeholder}
      />
    </div>
  );
}

export function Segmented({
  options,
  value,
  onChange,
}: {
  options: { key: string; label: string }[];
  value: string;
  onChange: (k: string) => void;
}) {
  return (
    <div className="segmented">
      {options.map((o) => (
        <button
          key={o.key}
          className={`seg${value === o.key ? " active" : ""}`}
          onClick={() => onChange(o.key)}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function Pagination({
  page,
  pageCount,
  total,
  onPage,
}: {
  page: number;
  pageCount: number;
  total: number;
  onPage: (p: number) => void;
}) {
  if (pageCount <= 1) return null;
  return (
    <div className="pagination">
      <span className="subtle text-[12.5px]">
        {total} item{total === 1 ? "" : "s"} · page {page + 1} of {pageCount}
      </span>
      <div className="row" style={{ gap: 6 }}>
        <button className="icon-btn" disabled={page === 0} onClick={() => onPage(page - 1)}>
          <ChevronLeft size={16} />
        </button>
        <button
          className="icon-btn"
          disabled={page >= pageCount - 1}
          onClick={() => onPage(page + 1)}
        >
          <ChevronRight size={16} />
        </button>
      </div>
    </div>
  );
}

/** Client-side pagination over an in-memory list. */
export function usePaged<T>(items: T[], pageSize = 10) {
  const [page, setPage] = useState(0);
  const pageCount = Math.max(1, Math.ceil(items.length / pageSize));
  const clamped = Math.min(page, pageCount - 1);
  const slice = useMemo(
    () => items.slice(clamped * pageSize, clamped * pageSize + pageSize),
    [items, clamped, pageSize],
  );
  return { page: clamped, setPage, pageCount, total: items.length, slice };
}
