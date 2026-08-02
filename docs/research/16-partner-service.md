# 16 — Partner Service Extraction: Can the Fleet Domain Stand Alone?

> **Status:** ✅ **Implemented** (2026-08-02) as `saarathi-partners` (:8087). This doc is the
> decision record; the "Open decisions" in §8 were resolved as noted there. Source of truth for
> the fleet/partner service boundary. Companion to [15 — Service Decomposition](15-service-decomposition.md).
>
> **TL;DR:** Yes — worth doing. Partner/fleet is a genuine bounded context (B2B tenancy) and
> is today the **most fragmented** domain in the codebase, smeared across four places. A
> `saarathi-partners` service is the highest-clarity consolidation available. The one hard
> boundary is identical to payments: the partner money that settles **inside the trip
> transaction** (revenue-share, corporate-tab charge, partner-funded bonus) must stay in
> `rides`. Everything else consolidates.

---

## 1. The question

> "Find the possibility of separating the partner as a separate service, and how it will
> affect other services. Partner is a separate entity from rides, so isolation makes sense."

Correct instinct. Partner/fleet is a distinct actor set (fleet owners/managers, corporate
riders), a distinct security surface (B2B multi-tenant RBAC), and a distinct scaling profile.
And unlike most domains, it's currently **fragmented across four services**, which is itself
an argument for consolidation.

---

## 2. Where partner code lives today (the fragmentation)

| Service | Partner surface |
|---------|-----------------|
| **auth** | Governance + tenancy master tables (`partners`, `partner_members`, `partner_drivers`, `partner_riders`) + `partner_admin_routes.rs` (create/suspend/update partner, commission-share config) + `partner_portal_routes.rs` (member/driver/rider roster + partner RBAC) |
| **rides** | Fleet money + ops: `routes/partner.rs` (wallet view, topup init/confirm, payout init, ledger view + verify, fleet analytics, partner campaign CRUD) + `partner_ledger.rs` (append wrapper, `balance`, `accrue_commission_share`, `corporate_precheck`, `charge_corporate_ride`, `verify_chain`) + settlement hooks in `settle.rs` and `bonus.rs` |
| **payments** | The partner-payout branch of the PSP `payout_callback` (settles `partner_payouts`, reverses via `partner_ledger` append) |
| **core** | `saarathi_core::partner_ledger::append` — the shared hash-chain writer (advisory lock `770002`) |

**Tables & schema ownership today:** `partners`, `partner_members`, `partner_drivers`,
`partner_riders` are created by **auth**; `partner_wallets`, `partner_ledger`,
`partner_payouts`, `partner_topup_intents`, and the `campaigns.partner_id`/`funded_by`
columns by **rides**. The tenancy tables FK into `users` (auth); the ledger/wallet tables are
referenced at trip settlement (rides).

---

## 3. The one hard boundary — trip-transaction money (stays in rides)

Three partner money operations run **inside the trip-completion transaction**
(`rides::settle::on_completion`, one `begin()..commit()`), and cannot leave it without a
saga/compensation:

| Operation | Where | Why it can't move |
|-----------|-------|-------------------|
| `accrue_commission_share` | `settle.rs` (~L96) | The fleet's revenue-share is carved from the platform's ≤10% **in the same COMMIT** as the ledger entry + driver payout. |
| `charge_corporate_ride` | `settle.rs` (~L75) | A corporate-tab trip debits the fleet wallet atomically with completion. |
| partner-funded bonus deduct | `bonus.rs` (~L144) | A fleet-funded driver bonus debits the partner wallet in the same tx as the payout it funds. |
| `corporate_precheck` | `routes/rides.rs` (~L154) | Booking-time eligibility read (wallet funded, monthly cap). Could be an RPC, but it's a cheap shared-DB read — keep it local. |

This is the exact atomicity constraint from [doc 15](15-service-decomposition.md): trip +
partner-money must be one commit to preserve the append-only hash-chained ledger and the
90/10/1 split.

**Crucially, cross-service writes to `partner_ledger` already work.** The `payments` service
*already* appends to `partner_ledger` (payout reversals) while `rides` appends at settlement.
The `pg_advisory_xact_lock(770002)` in the core writer serialises the chain at the **Postgres**
level, not the process level — so multiple services writing the one partner ledger on a shared
DB keeps the chain linear and verifiable. Adding `saarathi-partners` as a third writer is safe.

---

## 4. What a `saarathi-partners` service would own

**Consolidates in (from auth):**
- Partner governance: create / suspend / update partner, commission-share config (clamped ≤10%).
- Roster + RBAC: members (invite/role/remove), fleet drivers (add/status, anti-poaching unique),
  corporate riders (add/status/monthly cap, one-active-tab unique).

**Consolidates in (from rides `routes/partner.rs`):**
- Partner wallet view, topup init + confirm, payout init, ledger view + `verify_chain`,
  fleet analytics/dashboards, partner campaign CRUD.

**Optionally (from payments):**
- The partner-payout PSP callback (keeps the whole fleet payout lifecycle in one service) — or
  leave it in payments to keep all PSP webhooks centralised. Minor either way.

**Stays in rides** (trip-tx coupled): the three settlement hooks above + `corporate_precheck`,
writing `partner_wallets`/`partner_ledger` via the shared `saarathi_core::partner_ledger`
writer on the shared DB.

**Stays in core:** `partner_ledger::append` remains the single shared writer.

---

## 5. Effect on each service

| Service | Effect |
|---------|--------|
| **auth** | Sheds `partner_admin_routes.rs` + `partner_portal_routes.rs` (~2 files). Still owns `users`/`drivers` that partner tables FK into → **shared DB stays**. |
| **rides** | Sheds `routes/partner.rs` (~460 lines of fleet endpoints). **Keeps** `partner_ledger.rs`'s settlement functions (`accrue_commission_share`, `charge_corporate_ride`, `corporate_precheck`) + the `settle.rs`/`bonus.rs` hooks. Net: rides gets leaner, its trip tx unchanged. |
| **payments** | Unchanged (or hand the partner-payout callback to partners). |
| **core** | Unchanged. |
| **dashboard** | Partner portal pages repoint from auth/rides base URLs to the partners service. |

Ports would extend the existing scheme (auth 8081 … campaigns 8086 → **partners 8087**).

---

## 6. Drawbacks (honest)

- **Another shared-DB service** — same "distributed monolith" tradeoff as payments/campaigns:
  independent deploy/ownership + isolated B2B security surface, but coupled data (rides still
  reads/writes partner tables at settlement).
- **Schema ownership gets fuzzier.** Partner tables FK into `users` (auth) and are written at
  settlement (rides). Cleanest: **partners service owns the partner-table DDL**; auth and rides
  read/write them on the shared DB. Own-DB is *not* viable without also moving settlement
  (breaks atomicity) and severing the `users` FKs.
- **Three writers on `partner_ledger`** (rides settlement, payments reversal, partners
  topup/payout) — technically fine via the advisory lock, but it's a coordination point to keep
  documented.
- **Effort** touches three services + the dashboard — larger blast radius than the previous
  splits, and it moves compliance-adjacent money + RBAC, so it needs careful smoke coverage
  (fleet phase 1/2/3 already in `smoke.sh`).

---

## 7. Recommendation

**Do it** — partner is the cleanest remaining domain boundary and the current four-way
fragmentation is a real maintainability cost. Scope:

1. **`saarathi-partners` (:8087)** owns governance + roster/RBAC (from auth) + fleet money-ops,
   dashboards, and campaign CRUD (from rides). Shared Postgres; partners service owns the
   partner-table DDL.
2. **Keep** the three trip-tx settlement hooks + `corporate_precheck` in rides, writing via the
   shared core `partner_ledger` writer.
3. Leave the partner-payout PSP callback in payments (centralised webhooks) unless you want the
   full fleet payout lifecycle in one place.

If the effort feels too large for one step, the **safe first slice** is governance + roster out
of auth (pure REST + tenancy tables, zero trip-tx coupling), then fleet money-ops out of rides
in a second pass.

---

## 8. Open decisions (resolved)

1. **Scope now:** ✅ Full consolidation — governance + roster (from auth) + fleet money-ops,
   dashboards, and campaign CRUD (from rides) all moved to `saarathi-partners`.
2. **Partner-payout callback:** ✅ Kept centralised in `payments` (all PSP webhooks in one place).
3. **DB ownership:** ✅ Shared Postgres; the new service is **schema-less** (like payments/campaigns)
   — auth keeps the identity + partner-table DDL, rides keeps the money-table DDL, partners
   reads/writes them. Own-DB stays off the table while settlement is in rides.

**As built:** `saarathi-partners` (:8087) owns `/v1/admin/partners` (governance), the
`/v1/partner/*` portal (memberships, members, drivers, riders) and fleet money
(wallet/topup/payouts/ledger/verify/analytics/campaigns). Rides keeps `settle::on_completion`
+ `partner_ledger` settlement functions (`accrue_commission_share`, `charge_corporate_ride`,
`corporate_precheck`); `payments` keeps the partner-payout callback. The shared hash-chain
writer + `balance`/`verify_chain` live in `saarathi_core::partner_ledger`. Full seven-service
smoke (fleet phases 1–3) passes with the partner ledger chain intact across writers.
