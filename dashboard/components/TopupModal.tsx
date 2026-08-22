"use client";

import { rides, type CreditPlan } from "@/lib/api";
import { useEffect, useState } from "react";
import { Modal } from "./Modal";

const CUSTOM = "__custom__";

/** Staff-initiated credit top-up for a rider or driver — bypasses the PSP
 * entirely, so this is for goodwill credits / dispute resolution / onboarding
 * incentives, not a substitute for the normal self-serve top-up flow.
 * Amount can be freeform, or picked against an active credit plan (applies
 * that plan's bonus on top, same as a rider would get self-serve). */
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
  const [plans, setPlans] = useState<CreditPlan[]>([]);
  const [planId, setPlanId] = useState<string>(CUSTOM);
  const [amount, setAmount] = useState("500");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    rides
      .listCreditPlans()
      .then((all) => setPlans(all.filter((p) => p.status === "active")))
      .catch(() => setPlans([]));
  }, [open]);

  const plan = plans.find((p) => p.id === planId);

  async function submit() {
    const n = Number(amount);
    if (!(n > 0)) {
      setError("Enter a positive amount.");
      return;
    }
    if (plan && (n < Number(plan.min_amount) || n > Number(plan.max_amount))) {
      setError(`Amount must be between NPR ${plan.min_amount} and NPR ${plan.max_amount} for this plan.`);
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const res = await rides.adminTopup(userId, kind, n, plan?.id);
      setAmount("500");
      setPlanId(CUSTOM);
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
        <label>Credit plan</label>
        <select className="input" value={planId} onChange={(e) => setPlanId(e.target.value)}>
          <option value={CUSTOM}>Custom amount (no bonus)</option>
          {plans.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name} — NPR {p.min_amount}–{p.max_amount}
              {Number(p.bonus_percent) > 0 ? `, +${p.bonus_percent}% bonus` : ""}
            </option>
          ))}
        </select>
      </div>
      <div className="field">
        <label>Amount (NPR){plan ? ` — between ${plan.min_amount} and ${plan.max_amount}` : ""}</label>
        <input
          className="input"
          type="number"
          min={plan ? Number(plan.min_amount) : 1}
          max={plan ? Number(plan.max_amount) : undefined}
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          autoFocus
        />
      </div>
      {plan && Number(plan.bonus_percent) > 0 && Number(amount) > 0 && (
        <p className="notice" style={{ marginTop: 0 }}>
          NPR {amount} + {((Number(amount) * Number(plan.bonus_percent)) / 100).toFixed(2)} bonus ={" "}
          <b>
            NPR{" "}
            {(Number(amount) + (Number(amount) * Number(plan.bonus_percent)) / 100).toFixed(2)}{" "}
            credited
          </b>
        </p>
      )}
    </Modal>
  );
}
