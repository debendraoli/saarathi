// Live push for staff notifications (`/v1/staff/ws`), replacing the
// dashboard's previous polling of `GET /v1/notifications`. One shared
// WebSocket connection for the whole app — `NotificationBell` and the
// sidebar's badge-count refresh both subscribe to the same stream instead
// of each opening (and reconnecting) their own socket.

import { auth, type AppNotification } from "./api";

const API_BASE = process.env.NEXT_PUBLIC_API_BASE ?? "http://localhost:8080";

function wsUrl(): string | null {
  const token = auth.access;
  if (!token) return null;
  const base = API_BASE.replace(/^http/, "ws");
  return `${base}/v1/staff/ws?token=${encodeURIComponent(token)}`;
}

type Handler = (n: AppNotification) => void;

let socket: WebSocket | null = null;
let reconnectAttempt = 0;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
const handlers = new Set<Handler>();

function scheduleReconnect() {
  if (reconnectTimer !== null) return;
  const attempt = reconnectAttempt++;
  const delayMs = (attempt >= 4 ? 15 : 2 ** attempt) * 1000; // 1,2,4,8,15s…
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, delayMs);
}

function connect() {
  if (handlers.size === 0) return; // nothing subscribed — don't bother
  const url = wsUrl();
  if (!url) {
    // Not signed in yet — try again shortly rather than giving up for good
    // (a subscriber can mount before the auth redirect/login flow settles).
    scheduleReconnect();
    return;
  }
  const ws = new WebSocket(url);
  socket = ws;
  ws.onopen = () => {
    // Only reset backoff once the handshake actually succeeds — resetting
    // it right after `new WebSocket()` (before open/error is known) would
    // mean a persistently-down backend never actually backs off, hammering
    // the endpoint once a second indefinitely instead of growing the delay.
    reconnectAttempt = 0;
  };
  ws.onmessage = (e) => {
    try {
      const msg = JSON.parse(e.data);
      if (msg.type !== "notification") return;
      const n: AppNotification = {
        id: msg.id,
        class: msg.class,
        title: msg.title,
        body: msg.body ?? null,
        link: msg.link ?? null,
        read_at: null,
        created_at: msg.created_at,
      };
      for (const h of handlers) h(n);
    } catch {
      // ignore malformed frames
    }
  };
  const onCloseOrError = () => {
    if (socket === ws) socket = null;
    if (handlers.size > 0) scheduleReconnect();
  };
  ws.onclose = onCloseOrError;
  ws.onerror = onCloseOrError;
}

/**
 * Subscribe to live staff notifications. Returns an unsubscribe function.
 * The underlying socket connects on the first subscriber and closes once
 * the last one unsubscribes.
 */
export function subscribeStaffNotifications(handler: Handler): () => void {
  handlers.add(handler);
  if (handlers.size === 1) connect();
  return () => {
    handlers.delete(handler);
    if (handlers.size === 0) {
      if (reconnectTimer !== null) {
        clearTimeout(reconnectTimer);
        reconnectTimer = null;
      }
      socket?.close();
      socket = null;
      reconnectAttempt = 0;
    }
  };
}
