"use client";

import { rides, type SupportMessage, type SupportThread } from "@/lib/api";
import { useEffect, useState } from "react";

export default function SupportPage() {
  const [threads, setThreads] = useState<SupportThread[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [messages, setMessages] = useState<SupportMessage[]>([]);
  const [reply, setReply] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [sending, setSending] = useState(false);

  async function loadThreads() {
    setError(null);
    try {
      setThreads(await rides.listSupportThreads());
    } catch (e) {
      setError((e as Error).message);
    }
  }

  async function loadMessages(userId: string) {
    try {
      setMessages(await rides.supportThreadMessages(userId));
    } catch (e) {
      setError((e as Error).message);
    }
  }

  useEffect(() => {
    loadThreads();
    const t = setInterval(loadThreads, 5000);
    return () => clearInterval(t);
  }, []);

  useEffect(() => {
    if (!selected) return;
    loadMessages(selected);
    const t = setInterval(() => loadMessages(selected), 5000);
    return () => clearInterval(t);
  }, [selected]);

  async function send() {
    const body = reply.trim();
    if (!body || !selected || sending) return;
    setSending(true);
    setReply("");
    try {
      await rides.replySupportThread(selected, body);
      await loadMessages(selected);
      await loadThreads();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSending(false);
    }
  }

  const active = threads.find((t) => t.user_id === selected);

  return (
    <div className="stack">
      <div>
        <h1 className="page-title">Support</h1>
        <p className="subtle">Rider/driver/merchant messages. Refreshes automatically.</p>
      </div>
      {error && <div className="error">{error}</div>}
      <div style={{ display: "flex", gap: 16, alignItems: "flex-start" }}>
        <div className="card" style={{ flex: "0 0 320px", padding: 0, overflow: "hidden" }}>
          {threads.length === 0 ? (
            <p className="subtle" style={{ margin: 16 }}>
              No support messages yet.
            </p>
          ) : (
            threads.map((t) => (
              <button
                key={t.user_id}
                onClick={() => setSelected(t.user_id)}
                style={{
                  display: "block",
                  width: "100%",
                  textAlign: "left",
                  padding: "12px 16px",
                  border: "none",
                  borderBottom: "1px solid var(--color-border)",
                  background: t.user_id === selected ? "var(--color-surface-2)" : "transparent",
                  cursor: "pointer",
                }}
              >
                <div className="row" style={{ justifyContent: "space-between" }}>
                  <strong>{t.user_name || t.user_phone || t.user_id.slice(0, 8)}</strong>
                  {t.unread > 0 && <span className="badge rejected">{t.unread}</span>}
                </div>
                <div className="subtle" style={{ fontSize: 13, marginTop: 4 }}>
                  {t.last_message.length > 60 ? `${t.last_message.slice(0, 60)}…` : t.last_message}
                </div>
                <div className="subtle" style={{ fontSize: 11, marginTop: 2 }}>
                  {new Date(t.last_at).toLocaleString()}
                </div>
              </button>
            ))
          )}
        </div>

        <div className="card" style={{ flex: 1, minHeight: 420, display: "flex", flexDirection: "column" }}>
          {!selected || !active ? (
            <p className="subtle">Select a conversation.</p>
          ) : (
            <>
              <div style={{ marginBottom: 12 }}>
                <strong>{active.user_name || active.user_phone || active.user_id}</strong>
                {active.user_phone && <div className="subtle">{active.user_phone}</div>}
              </div>
              <div
                style={{
                  flex: 1,
                  overflowY: "auto",
                  display: "flex",
                  flexDirection: "column",
                  gap: 8,
                  padding: 8,
                  background: "var(--color-surface-2)",
                  borderRadius: 8,
                  marginBottom: 12,
                }}
              >
                {messages.map((m) => (
                  <div
                    key={m.id}
                    style={{
                      alignSelf: m.sender_role === "staff" ? "flex-end" : "flex-start",
                      maxWidth: "70%",
                      background:
                        m.sender_role === "staff" ? "var(--color-brand)" : "var(--color-elevated)",
                      color: m.sender_role === "staff" ? "var(--color-brand-ink)" : "inherit",
                      border: m.sender_role === "staff" ? "none" : "1px solid var(--color-border)",
                      borderRadius: 12,
                      padding: "8px 12px",
                    }}
                  >
                    <div>{m.body}</div>
                    <div style={{ fontSize: 10, opacity: 0.7, marginTop: 4 }}>
                      {new Date(m.created_at).toLocaleTimeString()}
                    </div>
                  </div>
                ))}
              </div>
              <div className="row" style={{ gap: 8 }}>
                <input
                  className="input"
                  style={{ flex: 1 }}
                  placeholder="Type a reply…"
                  value={reply}
                  onChange={(e) => setReply(e.target.value)}
                  onKeyDown={(e) => e.key === "Enter" && send()}
                />
                <button className="btn primary" disabled={sending} onClick={send}>
                  Send
                </button>
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
