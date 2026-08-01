"use client";

import { auth, type User } from "@/lib/api";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useState } from "react";

const SECTIONS = [
  { title: "Operations", items: [
    { href: "/live", label: "Live Tracking" },
    { href: "/rides", label: "Rides History" },
    { href: "/sos", label: "SOS Console" },
    { href: "/reports", label: "Reports" },
    { href: "/complaints", label: "Complaints" },
  ] },
  { title: "Insights", items: [
    { href: "/analytics", label: "Analytics" },
    { href: "/leaderboards", label: "Leaderboards" },
  ] },
  { title: "Compliance", items: [
    { href: "/drivers/new", label: "On-site KYC" },
    { href: "/drivers", label: "Driver Verification" },
  ] },
  { title: "Finance", items: [
    { href: "/ledger", label: "Ledger" },
    { href: "/payouts", label: "Payouts" },
    { href: "/credit-plans", label: "Credit Plans" },
  ] },
  { title: "Growth", items: [
    { href: "/campaigns", label: "Campaigns & Offers" },
    { href: "/surge", label: "Surge Hours" },
  ] },
  { title: "Platform", items: [
    { href: "/flags", label: "Feature Flags" },
  ] },
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
        {SECTIONS.map((section) => (
          <div key={section.title}>
            <div className="nav-section">{section.title}</div>
            {section.items.map((item) => (
              <Link
                key={item.href}
                href={item.href}
                className={`nav-item ${pathname.startsWith(item.href) ? "active" : ""}`}
              >
                {item.label}
              </Link>
            ))}
          </div>
        ))}
        <div className="nav-section">Coming soon</div>
        <span className="nav-item" style={{ opacity: 0.5 }}>Pricing Config</span>
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
  if (pathname.startsWith("/drivers/new")) return "On-site Driver KYC";
  if (pathname.startsWith("/drivers")) return "Driver Verification";
  if (pathname.startsWith("/campaigns")) return "Campaigns & Offers";
  if (pathname.startsWith("/surge")) return "Surge Hours";
  if (pathname.startsWith("/flags")) return "Feature Flags";
  if (pathname.startsWith("/analytics")) return "Analytics";
  if (pathname.startsWith("/live")) return "Live Tracking";
  if (pathname.startsWith("/sos")) return "SOS Console";
  if (pathname.startsWith("/reports")) return "Reports";
  if (pathname.startsWith("/ledger")) return "Ledger";
  if (pathname.startsWith("/payouts")) return "Payouts";
  if (pathname.startsWith("/credit-plans")) return "Credit Plans";
  if (pathname.startsWith("/rides")) return "Rides History";
  if (pathname.startsWith("/complaints")) return "Complaints";
  if (pathname.startsWith("/leaderboards")) return "Leaderboards";
  return "";
}
