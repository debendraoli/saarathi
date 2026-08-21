# 13 — Revenue, Credits & Bargaining

> Scope: How Saarathi makes money **inside the legal 10% commission ceiling**, plus two features requested for the model: a **prepaid driver credit balance** (drivers top up; the platform's per-ride cut is drawn from it instead of chasing cash), and a **bounded fare-bargaining** feature. This extends the unit economics in [07](07-financial-model.md), the pricing clamp in [05 §5](05-technical-architecture.md), and the dispatch engine in [12 E5](12-execution-roadmap.md). It is a **planning** doc — build phases are in §8.
>
> **2026-08-21 revision:** the time-boxed "unlimited pass" subscription model originally described here (§4.2, retained below struck through for history) has been **retired** before ever reaching drivers. It always needed a fair-cap reconciliation and lawyer sign-off to stay under the 90%-floor guarantee; the always-on per-ride credit draw below achieves the same "no cash-debt-chasing" goal without ever charging more than the standard commission, so the fair-cap safety net becomes unnecessary. `subscription_passes` is frozen (kept for historical audit only); any pass still active at migration time was prorate-refunded into the driver's credit balance. See `backend/services/rides/src/db.rs::migrate_off_subscriptions` and `backend/services/rides/src/routes/credits.rs`.

---

## 1. The constraint that shapes everything (recap)
The 2082 standard caps **platform commission at 10%** and fares at **NPR 25/km (2W) / 55/km (4W)**, with driver keeping **≥90%**. You **cannot** raise take-rate to fix economics ([07 §1](07-financial-model.md)). So revenue must be **diversified and legal**, and the master variable stays **jobs per driver per day**.

---

## 2. How others monetize — and what's legal here
| Player | Model | Legal in Nepal? |
|--------|-------|-----------------|
| Uber / Pathao | 15–30% commission | ❌ over the 10% cap |
| **inDrive** | Driver pays a **small per-ride fee or subscription** (not %), + **P2P fare bargaining** | ✅ **closest fit** — a lead/access-fee model sits naturally under a commission cap |
| Careem/others | Subscriptions, ads, fintech | ✅ as add-ons |

> 🎯 **Read:** the inDrive-style **prepaid access model + bargaining** is *more* compatible with Nepal's cap than percentage commission — and it's exactly what the founder proposed. We adopt it as a **portfolio** alongside the ≤10% commission, with legal guardrails.

---

## 3. The revenue portfolio
| # | Line | Who pays | Mechanism | Legal fit |
|---|------|----------|-----------|-----------|
| 1 | **Commission (core)** | rider (from fare) | ≤10% per trip (built, [E2](12-execution-roadmap.md)) | ✅ within cap |
| 2 | **Driver prepaid credits** | driver | standard commission **drawn from a prepaid balance** instead of chasing cash — never exceeds the 10% cap by construction | ✅ within cap, no fair-cap needed |
| 3 | ~~Driver subscription pass~~ *(retired 2026-08-21)* | driver | ~~flat fee for a period → keep 100% of fares~~ | superseded by #2 |
| 4 | **Rider prepaid wallet (Saarathi Credits)** | rider | top-up balance to pay fares (cash-lite) + float | ✅ not extra take; improves cash flow/retention |
| 5 | **Delivery merchant commission** | merchant | separate, config-driven ([08 §5](08-delivery-system.md)) | ✅ delivery not bound by the ride cap |
| 6 | **Fintech (float + micro-credit)** | — | interest/float on prepaid balances; ledger-based driver advances ([12 §5 bet 3](12-execution-roadmap.md)) | ✅ later, with NRB view |
| 7 | **Promoted merchant listings / ads** | merchant | marketplace visibility | ✅ later |

> The **10% commission stays the backbone**; credits/subscriptions are a **driver-friendly alternative** that can *lower* the effective take for active drivers (a retention weapon), never raise it.

---

## 4. Credits (the top-up model, current design)

### 4.1 Two credit accounts
- **Driver credit account** — the driver **pre-loads credits**; on every **cash** trip, the platform's standard commission + accident fund is **deducted from credits** on completion, instead of the cash-owed reconciliation in [04 §3.3](04-operational-procedures.md) (digital trips are unaffected — the platform already holds the fare and nets its cut directly). A driver needs a **positive balance to accept jobs**; hit zero → top up to continue (enforced at offer-acceptance, `saarathi-rides` `dispatch::accept_offer`). This is the "driver needs to top up credits to take rides/delivery" mechanic — and it kills debt-chasing in a cash market.
- **Rider/customer credit account** — prepaid **Saarathi Credits** to pay fares (top up via eSewa/Khalti/Fonepay). Improves cash flow, reduces cash handling, and enables **bonus credits** ("buy 500, get 550" = a platform-funded promo via the [campaigns engine](09-notifications-and-referrals.md)).

### 4.2 ~~"Unlimited credits for a certain time" = the subscription pass~~ — retired
*(2026-08-21: this section described a time-boxed "unlimited pass" — flat fee for a period, 0% commission while active. It's been dropped. §4.1's per-ride credit draw already prevents cash-debt-chasing without a separate subscription tier, and dropping it removes the compliance surface area in §4.3 below entirely — no fee mechanism here can ever exceed the standard ≤10% commission, so there's nothing to reconcile. Kept struck through, not deleted, since the launch-supply-seeding idea it carried — free/discounted access for early drivers — may resurface as a straightforward commission-rate promo rather than a separate pass type.)*

### 4.3 ~~The non-negotiable compliance guardrail — "never more than 10%"~~ — no longer needed
*(Retired with §4.2. The fair-cap reconciliation existed solely to guarantee a subscription/access-fee driver's 90% floor; since §4.1's credit draw is always exactly the standard commission, the guarantee holds by construction and there is nothing left to reconcile or get lawyer sign-off on for this mechanism.)*

---

## 5. Bargaining / fare negotiation (bounded, legal)

> This revisits the earlier "no haggling" stance in [03 §2.3](03-user-flows.md): we keep the **transparent metered fare as the anchor and the legal ceiling**, and add **optional, bounded** negotiation on top — the familiar local *mol-mol*, made safe.

### 5.1 How it works
```mermaid
flowchart TD
    A[Algorithmic fare = routing → legal clamp] --> B{Rider chooses}
    B -->|Accept| P[Book at algorithmic fare - fast path]
    B -->|Propose fare| C[Rider counter within floor..ceiling]
    C --> D[Dispatch offer carries proposed fare]
    D --> E{Driver}
    E -->|Accept proposed| P2[Book at agreed fare]
    E -->|Counter within band| F[Rider sees counter]
    F -->|Accept| P2
    F -->|Timeout| P
    P2 --> G[Commission/fund computed on AGREED fare]
```
1. The **algorithmic fare** (routing → legal clamp) is the default and the **hard maximum**.
2. The rider can **accept** (one tap) or **propose** a different fare.
   - Propose **lower** for a deal (high supply / regulars).
   - Propose **higher** to attract a driver in low supply — but **capped at the legal ceiling** (never above 25/55 per km × 1.20 surge).
3. The proposal rides along in the **dispatch offer** ([E5](12-execution-roadmap.md)); a driver **accepts** or **counters within the band**.
4. The rider accepts a counter → trip. *("Customer accepts the offered fee eventually"* — the convergence.)

### 5.2 Guardrails (make-or-break)
- **Never above the legal cap** — the [pricing clamp](05-technical-architecture.md) is re-applied to any agreed fare.
- **A driver-protecting floor** (≥ minimum fare / configurable) — no race to the bottom.
- **Commission + fund computed on the *agreed* fare** — driver still keeps ≥90% of whatever is agreed.
- **Time-boxed, few rounds** — auto-fallback to the algorithmic fare; no endless haggling.
- **Transparency** — always show the algorithmic reference so riders see the fair price (anti-gouging, builds trust).
- **Feature-flagged per city/vertical** — launch **fixed/metered** (simple, trusted); enable **bargain** later where it lifts liquidity.

### 5.3 Why it fits Dang
Bargaining is culturally normal in local markets; inDrive proved it in emerging markets. Bounding it by law gives **familiar UX + legal safety + driver protection** — a differentiator national metered apps don't offer.

---

## 6. How this hooks into the built system
- **Credits** extend the driver wallet ([E2](12-execution-roadmap.md)) and land with **payments ([E3](12-execution-roadmap.md))** — top-ups are PSP flows; the per-ride fee draw is a ledger operation (`saarathi-core` `wallet::settle_driver_fee`, called from `saarathi-rides` `ledger::append`).
- **Bargaining** extends **dispatch ([E5](12-execution-roadmap.md))**: the trip request gains an optional `offered_fare`; offers carry the proposed fare; on acceptance the trip's fare fields are recomputed from the agreed fare **before** the ledger entry — always re-clamped to the law.

---

## 7. Data model (built)
- **`credit_accounts`** (user_id, kind `rider|driver`, balance, updated_at) — the non-withdrawable prepaid balance.
- **`credit_transactions`** (user_id, kind, txn_type `topup|payment|fee|payout|bonus|refund`, amount, balance_after, reference, trip_id, created_at) — append-only, mirrored into the ledger.
- **`driver_wallets`** (driver_id, balance, updated_at) — the separate withdrawable earnings balance (trip payouts on digital trips, bonuses, minus payouts).
- **`subscription_passes`** — frozen/historical only; see the 2026-08-21 revision note at the top of this doc.
- **`fare_negotiations`** (trip_id, algo_fare, floor, ceiling, rounds `jsonb`, agreed_fare, status).

---

## 8. Phasing
| Phase | Revenue work |
|-------|--------------|
| **1** | Commission (done) + cash-first. |
| **2** | **Driver prepaid credits** (per-ride draw, done — no subscription tier) + **rider prepaid wallet** + referrals; pilot **bargaining** in one zone. |
| **3** | Delivery merchant commission; bargaining for delivery. |
| **4** | Fintech (float, ledger-based micro-credit), promoted listings/ads. |

---

## 9. Legal caveats (do not skip)
1. ~~Subscription/access-fee vs the 10% cap~~ — moot since the subscription tier was retired (§4.2); the credit draw in §4.1 never exceeds the standard commission.
2. **Any agreed/bargained fare** must be **≤ legal ceiling** and **≥ configured floor**, commission on the agreed amount.
3. **Prepaid balances** touch NRB/PSP territory — confirm we ride PSP licenses and don't operate an unlicensed wallet ([02](02-regulatory-compliance.md)).
4. Every credit/fee/negotiation event is **config-driven, versioned, and audited**.

➡️ Related: [07 — Financial Model](07-financial-model.md) · [09 — Notifications & Referrals](09-notifications-and-referrals.md) · [12 — Execution Roadmap](12-execution-roadmap.md)
