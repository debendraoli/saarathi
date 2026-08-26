"use client";

import { NotificationBell } from "@/components/NotificationBell";
import { api, auth, places, rides, type User } from "@/lib/api";
import { subscribeStaffNotifications } from "@/lib/staffSocket";
import {
    BarChart3,
    Briefcase,
    Building2,
    Car,
    CreditCard,
    DollarSign,
    Flag,
    HeartPulse,
    LifeBuoy,
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
    UserCog,
    Users,
    Wallet,
    Zap,
    type LucideIcon,
} from "lucide-react";
import Link from "next/link";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { Suspense, useEffect, useState } from "react";

type CountKey = "kyc" | "sos" | "reports" | "complaints" | "places" | "support";
type NavItem = {
  href: string;
  label: string;
  icon: LucideIcon;
  countKey?: CountKey;
  staffOnly?: boolean; // super_admin/admin only — matches the backend's AdminUser gate
};
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
      { href: "/support", label: "Support", icon: LifeBuoy, countKey: "support" },
    ],
  },
  {
    title: "Users",
    items: [{ href: "/users", label: "Users", icon: Users }],
  },
  {
    title: "Drivers",
    items: [
      { href: "/drivers", label: "Driver KYC", icon: ShieldCheck, countKey: "kyc" },
      { href: "/drivers/all", label: "All Drivers", icon: Car },
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
      { href: "/rates", label: "Base Rates", icon: DollarSign },
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
      { href: "/staff", label: "Staff", icon: UserCog, staffOnly: true },
    ],
  },
];

const ALL_ITEMS = NAV.flatMap((g) => g.items);

/** The single best-matching nav href (longest prefix), so overlapping routes
 *  like /partner vs /partners never both light up. `driverListFrom` handles
 *  one specific ambiguity: /drivers/[id] is linked from both the KYC queue
 *  and the general directory, and a plain prefix match always resolves it to
 *  "/drivers" (the queue) — which then highlights the wrong sidebar item and
 *  implies you're looking at review-queue context when you came from the
 *  full driver list instead. */
function activeHref(pathname: string, driverListFrom: string | null): string | null {
  if (driverListFrom === "all" && /^\/drivers\/[^/]+$/.test(pathname)) {
    return "/drivers/all";
  }
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

// Now just a safety net for the rare count change that isn't accompanied by
// a staff notification — live push (see subscribeStaffNotifications below)
// handles the common case immediately, so this no longer needs to be tight.
const COUNT_POLL_MS = 120_000;

export default function AppLayout({ children }: { children: React.ReactNode }) {
  return (
    <Suspense fallback={null}>
      <AppLayoutInner>{children}</AppLayoutInner>
    </Suspense>
  );
}

function AppLayoutInner({ children }: { children: React.ReactNode }) {
  const router = useRouter();
  const pathname = usePathname();
  const driverListFrom = useSearchParams().get("from");
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
      const [kyc, sos, reports, complaints, placesQueue, supportThreads] = await Promise.all([
        api.listDrivers("queue").catch(() => []),
        rides.listSos().catch(() => []),
        rides.listReports().catch(() => []),
        rides.cancellations().catch(() => []),
        places.queue("pending").catch(() => []),
        rides.listSupportThreads().catch(() => []),
      ]);
      if (!active) return;
      setCounts({
        kyc: kyc.length,
        sos: sos.length,
        reports: reports.filter((r) => r.status === "open").length,
        complaints: complaints.filter((c) => !c.reviewed).length,
        places: placesQueue.length,
        support: supportThreads.filter((t) => t.unread > 0).length,
      });
    }
    loadCounts();
    // Refetch immediately on any live-pushed staff notification instead of
    // waiting up to COUNT_POLL_MS to notice — most count-affecting events
    // (a new SOS, a KYC submission, a complaint) already notify staff, so
    // this is the common case now. The interval stays as a long-interval
    // safety net for the rarer count change that isn't itself accompanied
    // by a notification, not the primary mechanism anymore.
    const unsubscribe = subscribeStaffNotifications(() => loadCounts());
    const t = setInterval(loadCounts, COUNT_POLL_MS);
    return () => {
      active = false;
      unsubscribe();
      clearInterval(t);
    };
  }, [ready]);

  if (!ready) return null;

  const active = activeHref(pathname, driverListFrom);
  const title = ALL_ITEMS.find((i) => i.href === active)?.label ?? "";
  const isAdmin = ["super_admin", "admin"].includes(user?.role ?? "");

  function logout() {
    auth.clear();
    router.replace("/login");
  }

  return (
    <div className="app">
      <aside className="sidebar">
        <div className="brand">
          <img className="logo" src="/logo.png" alt="Saarathi" /> Saarathi Ops
        </div>
        {NAV.map((group) => (
          <div key={group.title}>
            <div className="nav-section">{group.title}</div>
            {group.items.filter((item) => !item.staffOnly || isAdmin).map((item) => {
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
