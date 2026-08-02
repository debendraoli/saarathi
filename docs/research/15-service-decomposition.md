# 15 — Service Decomposition: What to Split, What to Keep (and Why)

> **Status:** Decision record awaiting founder input. Written 2026-08-02 after a full
> code-level coupling audit of the `rides` service. This is the source of truth for the
> "can payments be its own service?" question.
>
> **TL;DR:** Payment *operations* (top-ups, PSP webhooks, payouts, balance reads) can be
> split cleanly today. Payment *settlement at trip completion* (ledger + wallet deltas) is
> the compliance-load-bearing atomic path and should **not** be split into a network
> boundary without an outbox/saga — and for a solo founder pre-launch the atomicity you'd
> trade away is exactly your regulator-facing guarantee. Routing and campaign-management
> split cleanly and are the safe first moves.

---

## 1. The question

> "Why can't the payment service be separated? Carving payments/dispatch out would force
> sagas and weaken atomicity — is there a solution? Routing, campaigns, etc. make sense to
> separate. What are the drawbacks?"

Correct instinct on routing/campaigns. The payments answer is nuanced: **"payments" is two
different things**, and they split very differently.

---

## 2. What actually shares a transaction (the crux)

Trip completion is **one atomic DB transaction** in `rides` (`routes/rides.rs`, the
`update_status` handler, `begin() … commit()`). On first completion it writes, in order:

| Step | Tables | Module |
|------|--------|--------|
| Lock + read trip (`FOR UPDATE`) | `trips` | rides |
| Update status → completed | `trips` | rides |
| Check active subscription pass (may zero commission) | `subscription_passes` | payments |
| Override commission/payout | `trips` | rides |
| **Append hash-chained ledger entry + settle driver wallet** | `ledger_entries`, `driver_wallets` | ledger |
| Settle rider (wallet) **or** partner (corporate) | `credit_accounts`+`credit_transactions` / `partner_wallets`+`partner_ledger` | payments / partner_ledger |
| Grant driver campaign bonus | `campaigns`, `campaign_redemptions`, `driver_bonus_grants`, `driver_wallets`, (maybe) `partner_wallets`+`partner_ledger` | bonus |
| Accrue fleet revenue-share | `partner_ledger`, `partner_wallets` | partner_ledger |

**Every** `payments::*` and `ledger::append` function takes `&mut Transaction` — they are
*designed* to run inside the caller's transaction. The hash chain is serialized with
`pg_advisory_xact_lock(770001)` and a strictly monotonic global `seq`. That single `COMMIT`
is what makes **"trip completed" and "money moved & ledger sealed" true-or-false together.**

That atomicity is not incidental — it directly backs the golden rules:
append-only + hash-chained ledger, commission ≤10% (driver ≥90%), 1% accident fund.
A bug across a network boundary here is a **financial/legal** bug, not a cosmetic one.

---

## 3. "Payments" is two things

### A. Settlement at trip completion (HARD to split)
Ledger append, wallet debit/credit, corporate charge, bonus, revenue-share — the money
movement that *is* the trip. Splitting this off means the ledger append and rider debit
happen over the network, outside the trip's transaction. You lose the atomic `COMMIT`.

### B. Standalone payment operations (EASY to split)
Top-up intents, PSP payout webhook (`/v1/psp/payout/callback`), payout requests, balance
reads. These **already run as their own transactions with no trip tx around them.** They
can move to a `saarathi-payments` service today with almost no downside beyond the usual
shared-data discipline.

So the real decision is *scope*, not yes/no.

---

## 4. Is there a solution for (A)'s atomicity? Three, by effort

1. **Transactional outbox (recommended if/when we split settlement).**
   `rides` commits the trip **and** an `outbox` row in one transaction; a relay publishes to
   NATS JetStream; `saarathi-payments` consumes idempotently and performs settlement. You
   keep atomicity of *"trip + intent-to-settle"*; settlement becomes eventually-consistent
   **but guaranteed** (at-least-once + idempotency — the ledger already has a unique
   `trip_id`, so replays are harmless). The hash chain gets a **single writer** (the
   payments service), which is actually cleaner than today's inline appends.

2. **Full saga with compensation.** Payments owns its own DB; orchestrated over NATS; needs
   compensating actions (reverse ledger entry, un-debit wallet) and a per-trip state
   machine. Most isolation, most operational surface.

3. **Shared-DB, separate deployable.** Payments is its own binary but connects to the same
   Postgres, so a completion tx can still span modules. Independent deploy/scale, but **not**
   independent data — a "distributed monolith." Lowest effort, weakest isolation.

---

## 5. Drawbacks of splitting the settlement path (A)

- **Loss of atomic compliance invariants.** "Ledger sealed + 90/10/1 split exact" stops being
  one `COMMIT` and becomes eventual — provable only via idempotency + reconciliation jobs.
- **Hash chain needs a single writer.** Fine for a dedicated service, but `rides` can no
  longer append inline; *everything* ledger-touching must route through payments.
- **Bonus + revenue-share are entangled** with the ledger append in the same tx. Splitting
  payments forces a decision on where campaign-settlement and partner-ledger live too.
- **Operational cost for a solo founder:** outbox relay, idempotency, dead-letter handling,
  reconciliation, distributed tracing — ongoing burden, and the riskiest possible place to
  carry that burden (money + regulator).

---

## 6. What splits cleanly (low risk, clear pros)

| Candidate | Coupling to settlement tx | Verdict |
|-----------|---------------------------|---------|
| **Routing** (`routing.rs`) | None — stateless HTTP to Valhalla/OSRM, zero DB. Only consumer today is `pricing.rs` on the fare hot path. | **Split-friendly**, but see caveat below. |
| **Campaign *management*** (CRUD/budgets/rules) | None on the write side. Only the *completion-time bonus grant* is coupled. | Split the management plane; keep the settlement hook in rides. |
| **Payment operations (B)** | None — separate txs already. | Clean split; isolates PSP + webhook security surface. |
| **Dispatch** | Redis-only, no SQL tx. | Independent, but small; low payoff to split now. |
| **Settlement (A)** | The whole coupled tx. | Keep inline; only split via outbox (§4.1) after review. |

**Routing caveat (why not auto-built yet):** routing sits on the fare-estimate hot path,
and **fares feed the legal cap clamp**. A routing *service* adds a network hop
(`rides → routing-svc → Valhalla` vs `rides → Valhalla`) unless it earns its keep with a
**Redis route cache** (identical origin/dest pairs recur) and centralised engine-swap. A
routing *crate* (compile-time, zero hop) decouples the code but adds no runtime value while
rides is the only consumer. Either way the client must keep the **haversine offline
fallback** so fares survive if the service is unreachable. Because this touches a
compliance-adjacent path, it awaits explicit sign-off rather than an autonomous ship.

---

## 7. Recommendation

- **Do now (pros clearly outweigh):** split **routing** (as a service *with* a Redis cache,
  or first as a crate), **payment-operations (B)**, and **campaign-management**.
- **Do NOT now:** split **trip-settlement (A)**. Keep the atomic commit. It is your
  regulator-facing guarantee and the cost/risk of a saga pre-launch is not justified.
- **When you do split (A):** use the **transactional outbox** (§4.1) — service ownership
  without giving up the "trip + settlement-intent" atomic commit.

---

## 8. Open decisions (founder input needed)

1. **Split scope now:** routing? payment-operations? campaign-management? (settlement: default *no*)
2. **Settlement consistency (if/when):** outbox (recommended) / saga / shared-DB / defer.
3. **DB ownership per split service:** shared Postgres + separate schema (matches auth↔rides
   today) *or* own database per service (true isolation, no cross-service joins).

Until these are answered, settlement stays inline in `rides` and nothing on the money path
changes.
