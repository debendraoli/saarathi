"use client";

import { auth, type User } from "@/lib/api";
import {
    BarChart3,
    Briefcase,
    Building2,
    CreditCard,
    Flag,
    HeartPulse,
    LogOut,
    MessageSquare,
    Navigation,
    Receipt,
    Route,
    ShieldCheck,
    Siren,
    Tag,
    ToggleRight,
    Trophy,
    UserPlus,
    Wallet,
    Zap,
    type LucideIcon,
} from "lucide-react";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useState } from "react";

type NavItem = { href: string; label: string; icon: LucideIcon };
type NavGroup = { title: string; items: NavItem[] };

const NAV: NavGroup[] = [
  {
    title: "Overview",
    items: [
      { href: "/analytics", label: "Analytics", icon: BarChart3 },
      { href: "/live", label: "Live Ops", icon: Navigation },
      { href: "/leaderboards", label: "Leaderboards", icon: Trophy },
    ],
  },
  {
    title: "Trips & Safety",
    items: [
      { href: "/rides", label: "Rides", icon: Route },
      { href: "/sos", label: "SOS Console", icon: Siren },
      { href: "/reports", label: "Reports", icon: Flag },
      { href: "/complaints", label: "Complaints", icon: MessageSquare },
    ],
  },
  {
    title: "Drivers",
    items: [
      { href: "/drivers", label: "Verification", icon: ShieldCheck },
      { href: "/drivers/new", label: "On-site KYC", icon: UserPlus },
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
 *  like /partner vs /partners and /drivers vs /drivers/new never both light up. */
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
              return (
                <Link
                  key={item.href}
                  href={item.href}
                  className={`nav-item ${active === item.href ? "active" : ""}`}
                >
                  <Icon />
                  {item.label}
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
