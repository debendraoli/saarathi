"use client";

import { rides } from "@/lib/api";
import { useState } from "react";
import { Modal } from "./Modal";

/** Staff-initiated credit top-up for a rider or driver — bypasses the PSP
 * entirely, so this is for goodwill credits / dispute resolution / onboarding
 * incentives, not a substitute for the normal self-serve top-up flow. */
export function TopupModal({
  open,
  onClose,
  userId,
  kind,
  onDone,
}: {
  open: boolean;
  onClose: () => void;
  userId: string;
  kind: "rider" | "driver";
  onDone: (newBalance: string) => void;
}) {
  const [amount, setAmount] = useState("500");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit() {
    const n = Number(amount);
    if (!(n > 0)) {
      setError("Enter a positive amount.");
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const res = await rides.adminTopup(userId, kind, n);
      setAmount("500");
      onClose();
      onDone(res.balance);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={`Top up ${kind === "driver" ? "driver" : "rider"} credits`}
      footer={
        <>
          <button className="btn ghost" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button className="btn primary" onClick={submit} disabled={busy}>
            {busy ? "Crediting…" : "Credit account"}
          </button>
        </>
      }
    >
      {error && <div className="error">{error}</div>}
      <p className="subtle" style={{ marginTop: 0 }}>
        Credited immediately, no payment gateway involved. Every grant is attributed to your staff
        account in the ledger.
      </p>
      <div className="field">
        <label>Amount (NPR)</label>
        <input
          className="input"
          type="number"
          min="1"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          autoFocus
        />
      </div>
    </Modal>
  );
}
