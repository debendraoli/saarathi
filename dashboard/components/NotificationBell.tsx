"use client";

import { api, type AppNotification } from "@/lib/api";
import { subscribeStaffNotifications } from "@/lib/staffSocket";
import { Bell, X } from "lucide-react";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";

const TOAST_MS = 7_000;
const TOAST_EXIT_MS = 300;

type Toast = { n: AppNotification; leaving: boolean };

export function NotificationBell() {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [unread, setUnread] = useState(0);
  const [items, setItems] = useState<AppNotification[]>([]);
  const [toasts, setToasts] = useState<Toast[]>([]);
  const ref = useRef<HTMLDivElement>(null);

  function dismissToast(id: string) {
    setToasts((prev) => prev.map((t) => (t.n.id === id ? { ...t, leaving: true } : t)));
    setTimeout(() => {
      setToasts((prev) => prev.filter((t) => t.n.id !== id));
    }, TOAST_EXIT_MS);
  }

  // One-time fetch for the existing inbox/unread baseline — the socket only
  // ever pushes new arrivals from here on, it has no history of its own.
  // Merged rather than replaced: a notification the socket already pushed
  // while this fetch was in flight must not get silently dropped by an
  // overwrite that raced it (the socket subscription below starts at the
  // same time as this fetch, not after it).
  async function load() {
    try {
      const res = await api.notifications();
      setUnread(res.unread);
      setItems((prev) => {
        const byId = new Map(res.items.map((n) => [n.id, n]));
        for (const n of prev) if (!byId.has(n.id)) byId.set(n.id, n);
        return [...byId.values()].sort((a, b) => b.created_at.localeCompare(a.created_at));
      });
    } catch {
      // best-effort — the socket subscription below still works even if
      // this initial fetch fails; it just starts from an empty list.
    }
  }

  useEffect(() => {
    load();
  }, []);

  useEffect(() => {
    return subscribeStaffNotifications((n) => {
      setItems((prev) => [n, ...prev]);
      setUnread((u) => u + 1);
      setToasts((prev) => [...prev, { n, leaving: false }]);
      setTimeout(() => dismissToast(n.id), TOAST_MS);
    });
  }, []);

  useEffect(() => {
    function onClickOutside(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener("mousedown", onClickOutside);
    return () => document.removeEventListener("mousedown", onClickOutside);
  }, []);

  async function onRowClick(n: AppNotification) {
    if (!n.read_at) {
      setItems((prev) => prev.map((x) => (x.id === n.id ? { ...x, read_at: new Date().toISOString() } : x)));
      setUnread((u) => Math.max(0, u - 1));
      api.markNotificationRead(n.id).catch(() => {});
    }
    if (n.link && n.link.startsWith("/")) {
      setOpen(false);
      router.push(n.link);
    }
  }

  async function markAllRead() {
    setItems((prev) => prev.map((x) => ({ ...x, read_at: x.read_at ?? new Date().toISOString() })));
    setUnread(0);
    try {
      await api.markAllNotificationsRead();
    } catch {
      /* best-effort */
    }
  }

  return (
    <div className="notif-btn" ref={ref}>
      <button className="icon-btn" onClick={() => setOpen((o) => !o)} aria-label="Notifications">
        <Bell size={16} />
        {unread > 0 && <span className="notif-dot" />}
      </button>
      {open && (
        <div className="notif-panel">
          <div className="notif-head">
            <b className="text-[13.5px]">Notifications</b>
            {unread > 0 && (
              <button className="btn ghost" style={{ minHeight: 28, padding: "4px 10px" }} onClick={markAllRead}>
                Mark all read
              </button>
            )}
          </div>
          <div className="notif-list">
            {items.length === 0 && (
              <div className="subtle" style={{ padding: 20, textAlign: "center" }}>
                Nothing yet.
              </div>
            )}
            {items.map((n) => (
              <div
                key={n.id}
                className={`notif-row ${n.read_at ? "" : "unread"}`}
                onClick={() => onRowClick(n)}
              >
                <span className="title">{n.title}</span>
                {n.body && <span className="subtle">{n.body}</span>}
                <span className="faint text-[11.5px]">{new Date(n.created_at).toLocaleString()}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      <div className="toast-stack">
        {toasts.map((t) => (
          <div
            key={t.n.id}
            className={`toast${t.leaving ? " leaving" : ""}`}
            onClick={() => {
              onRowClick(t.n);
              dismissToast(t.n.id);
            }}
          >
            <button
              className="toast-close"
              aria-label="Dismiss"
              onClick={(e) => {
                e.stopPropagation();
                dismissToast(t.n.id);
              }}
            >
              <X size={13} />
            </button>
            <span className="title">{t.n.title}</span>
            {t.n.body && <span className="subtle">{t.n.body}</span>}
          </div>
        ))}
      </div>
    </div>
  );
}
