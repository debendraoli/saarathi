"use client";

import { NotificationBell } from "@/components/NotificationBell";
import { api, auth, places, rides, type User } from "@/lib/api";
import {
    BarChart3,
    Briefcase,
    Building2,
    CreditCard,
    Flag,
    HeartPulse,
    LogOut,
    MapPinned,
    MessageSquare,
    Navigation,
    Receipt,
    Route,
    ShieldCheck,
    Siren,
    Store,
    Tag,
    ToggleRight,
    Trophy,
    Users,
    Wallet,
    Zap,
    type LucideIcon,
} from "lucide-react";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useState } from "react";

type CountKey = "kyc" | "sos" | "reports" | "complaints" | "places";
type NavItem = { href: string; label: string; icon: LucideIcon; countKey?: CountKey };
type NavGroup = { title: string; items: NavItem[] };

const NAV: NavGroup[] = [
  {
    title: "Overview",
    items: [
      { href: "/analytics", label: "Analytics", icon: BarChart3 },
      { href: "/live", label: "Live Ops", icon: Navigation },
    ],
  },
  {
    title: "Trips & Safety",
    items: [
      { href: "/rides", label: "Rides", icon: Route },
      { href: "/sos", label: "SOS Console", icon: Siren, countKey: "sos" },
      { href: "/reports", label: "Reports", icon: Flag, countKey: "reports" },
      { href: "/complaints", label: "Complaints", icon: MessageSquare, countKey: "complaints" },
    ],
  },
  {
    title: "Riders",
    items: [{ href: "/riders", label: "Riders", icon: Users }],
  },
  {
    title: "Drivers",
    items: [
      { href: "/drivers", label: "Driver KYC", icon: ShieldCheck, countKey: "kyc" },
      { href: "/leaderboards", label: "Leaderboards", icon: Trophy },
    ],
  },
  {
    title: "Fleet Partners",
    items: [
      { href: "/partners", label: "Partners", icon: Building2 },
      { href: "/partner", label: "Partner Portal", icon: Briefcase },
    ],
  },
  {
    title: "Marketplace",
    items: [{ href: "/merchants", label: "Merchants", icon: Store }],
  },
  {
    title: "Community",
    items: [{ href: "/places", label: "Map Contributions", icon: MapPinned, countKey: "places" }],
  },
  {
    title: "Growth",
    items: [
      { href: "/campaigns", label: "Campaigns", icon: Tag },
      { href: "/surge", label: "Surge Hours", icon: Zap },
    ],
  },
  {
    title: "Finance",
    items: [
      { href: "/ledger", label: "Ledger", icon: Receipt },
      { href: "/payouts", label: "Payouts", icon: Wallet },
      { href: "/credit-plans", label: "Credit Plans", icon: CreditCard },
    ],
  },
  {
    title: "Platform",
    items: [
      { href: "/flags", label: "Feature Flags", icon: ToggleRight },
      { href: "/health", label: "Services", icon: HeartPulse },
    ],
  },
];

const ALL_ITEMS = NAV.flatMap((g) => g.items);

/** The single best-matching nav href (longest prefix), so overlapping routes
 *  like /partner vs /partners never both light up. */
function activeHref(pathname: string): string | null {
  let best: string | null = null;
  for (const { href } of ALL_ITEMS) {
    if (
      (pathname === href || pathname.startsWith(`${href}/`)) &&
      (!best || href.length > best.length)
    ) {
      best = href;
    }
  }
  return best;
}

const COUNT_POLL_MS = 30_000;

export default function AppLayout({ children }: { children: React.ReactNode }) {
  const router = useRouter();
  const pathname = usePathname();
  const [user, setUser] = useState<User | null>(null);
  const [ready, setReady] = useState(false);
  const [counts, setCounts] = useState<Partial<Record<CountKey, number>>>({});

  useEffect(() => {
    if (!auth.access) {
      router.replace("/login");
      return;
    }
    setUser(auth.user);
    setReady(true);
  }, [router]);

  useEffect(() => {
    if (!ready) return;
    let active = true;
    async function loadCounts() {
      const [kyc, sos, reports, complaints, placesQueue] = await Promise.all([
        api.listDrivers("queue").catch(() => []),
        rides.listSos().catch(() => []),
        rides.listReports().catch(() => []),
        rides.cancellations().catch(() => []),
        places.queue("pending").catch(() => []),
      ]);
      if (!active) return;
      setCounts({
        kyc: kyc.length,
        sos: sos.length,
        reports: reports.filter((r) => r.status === "open").length,
        complaints: complaints.length,
        places: placesQueue.length,
      });
    }
    loadCounts();
    const t = setInterval(loadCounts, COUNT_POLL_MS);
    return () => {
      active = false;
      clearInterval(t);
    };
  }, [ready]);

  if (!ready) return null;

  const active = activeHref(pathname);
  const title = ALL_ITEMS.find((i) => i.href === active)?.label ?? "";

  function logout() {
    auth.clear();
    router.replace("/login");
  }

  return (
    <div className="app">
      <aside className="sidebar">
        <div className="brand">
          <span className="logo">सा</span> Saarathi Ops
        </div>
        {NAV.map((group) => (
          <div key={group.title}>
            <div className="nav-section">{group.title}</div>
            {group.items.map((item) => {
              const Icon = item.icon;
              const count = item.countKey ? counts[item.countKey] : undefined;
              return (
                <Link
                  key={item.href}
                  href={item.href}
                  className={`nav-item ${active === item.href ? "active" : ""}`}
                >
                  <Icon />
                  {item.label}
                  {!!count && <span className="nav-count">{count > 99 ? "99+" : count}</span>}
                </Link>
              );
            })}
          </div>
        ))}
      </aside>

      <div className="main">
        <div className="topbar">
          <div className="title">{title}</div>
          <div className="row">
            <NotificationBell />
            <span className="subtle text-[13px]">
              {user?.full_name ?? user?.phone} · <b>{user?.role}</b>
            </span>
            <button className="btn ghost" onClick={logout}>
              <LogOut size={15} /> Sign out
            </button>
          </div>
        </div>
        <div className="content">{children}</div>
      </div>
    </div>
  );
}
