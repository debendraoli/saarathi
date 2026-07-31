"use client";

import { auth, type User } from "@/lib/api";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useState } from "react";

const NAV = [
  { href: "/drivers", label: "Driver Verification" },
];

export default function AppLayout({ children }: { children: React.ReactNode }) {
  const router = useRouter();
  const pathname = usePathname();
  const [user, setUser] = useState<User | null>(null);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    if (!auth.access) {
      router.replace("/login");
      return;
    }
    setUser(auth.user);
    setReady(true);
  }, [router]);

  if (!ready) return null;

  function logout() {
    auth.clear();
    router.replace("/login");
  }

  return (
    <div className="app">
      <aside className="sidebar">
        <div className="brand">
          <span className="dot" /> Saarathi Ops
        </div>
        <div className="nav-section">Compliance</div>
        {NAV.map((item) => (
          <Link
            key={item.href}
            href={item.href}
            className={`nav-item ${pathname.startsWith(item.href) ? "active" : ""}`}
          >
            {item.label}
          </Link>
        ))}
        <div className="nav-section">Growth</div>
        <Link
          href="/campaigns"
          className={`nav-item ${pathname.startsWith("/campaigns") ? "active" : ""}`}
        >
          Campaigns &amp; Offers
        </Link>
        <div className="nav-section">Coming soon</div>
        <span className="nav-item" style={{ opacity: 0.5 }}>Live Tracking</span>
        <span className="nav-item" style={{ opacity: 0.5 }}>Pricing Config</span>
        <span className="nav-item" style={{ opacity: 0.5 }}>Ledger</span>
      </aside>

      <div className="main">
        <div className="topbar">
          <div className="subtle">{titleFor(pathname)}</div>
          <div className="row">
            <span className="subtle">
              {user?.full_name ?? user?.phone} · <b>{user?.role}</b>
            </span>
            <button className="btn ghost" onClick={logout}>
              Sign out
            </button>
          </div>
        </div>
        <div className="content">{children}</div>
      </div>
    </div>
  );
}

function titleFor(pathname: string): string {
  if (pathname.startsWith("/drivers")) return "Driver Verification";
  if (pathname.startsWith("/campaigns")) return "Campaigns & Offers";
  return "";
}
