# 10 — Driver Experience, Earnings & Analytics

> Scope: The driver-facing insight layer — real-time earnings clarity, daily/weekly summaries, demand heatmaps, quality trends, incentive progress, and statements. In a market where **drivers are the scarce side** and switching cost is low, transparency is retention. This builds on the driver journey in [03 §3](03-user-flows.md), the wallet in [04 §3.3](04-operational-procedures.md), and reads from the immutable ledger + `trip_events` already in the system.

---

## 1. The strategic bet: transparency as a moat
Saarathi keeps **≥90% with the driver** (legal cap). That is a *structural* advantage over the ~global 20–30% take — but only if the driver **sees and believes it.** inDrive won emerging markets largely on **earnings transparency**; we go further because our economics are genuinely better. Every screen answers the driver's real question: *"How much did I actually make, and how do I make more?"*

## 2. How others do it & our difference
| | Uber / Pathao driver app | **Saarathi** |
|---|---|---|
| Earnings view | Post-hoc weekly statement | **Real-time net-per-job + live day total** |
| Take-rate visibility | Opaque / buried | **Explicit: fare → −10% −1% fund → your 89%+** |
| Guidance | Surge map | **Demand heatmap + pre-position nudges + "get-compliant" reminders** |
| Data footprint | Heavy app | **Low-data, cached, Nepali** — works on cheap Androids |
| Incentives | Quests | **Quests tied to the campaigns `driver_bonus` engine**, progress shown live |

## 3. What the driver sees

```mermaid
flowchart TD
    Home[Driver home] --> Live[Today: trips, online hrs vs 12h cap, gross, net, tips]
    Home --> Job[Per-job card: fare − commission − fund = your payout]
    Home --> Week[This week: earnings, best day, jobs/hr, acceptance, rating]
    Home --> Heat[Demand heatmap + hotspots now]
    Home --> Wallet[Wallet: balance owed/owed-to-you, settlement history]
    Home --> Quest[Incentives: "12 trips today → NPR 300 bonus" progress]
    Home --> Docs[Compliance: doc/QR expiry countdown]
    Home --> Stmt[Statements: export for tax / loan]
```

### 3.1 Earnings clarity (the core)
- **Per-job, up front:** show **net** (fare − 10% − 1% fund) *before* accepting — no surprises.
- **Live day tally:** gross, net, tips, jobs, online hours (with the **12-hour legal cap** counting down).
- **Weekly summary:** total, best day/zone, jobs/online-hour, cash-vs-digital split, and what drove it.

### 3.2 Insights that change behavior
- **Demand heatmap** (geohash cells: where requests exceed idle drivers now) + **pre-position nudges** toward bazaar/bus-park/college hotspots at peak ([04 §2](04-operational-procedures.md)).
- **Quality trends:** acceptance rate, cancellation rate, rating (rolling), and how each affects dispatch priority ([11](11-trust-safety-ratings-sos.md)) — shown as *coaching*, not punishment.
- **Utilization:** idle time vs on-job — nudges to opt into parcel/food to fill gaps ([08](08-delivery-system.md)).

### 3.3 Money & statements
- **Wallet view:** owed vs owed-to-you, negative-balance warning, settlement history, one-tap top-up.
- **Exportable statements** (daily/weekly/monthly) for **tax clearance and loan applications** — a real, differentiated benefit for a driver formalizing their livelihood, and it dovetails with the compliance docs they already need.

### 3.4 Incentives / quests
- **Quests** ("N trips today," "peak-hour bonus," "complete-rate ≥90% this week") are **`campaigns` of `audience=driver`** — the engine already exists in `saarathi-rides`; this surface shows **live progress bars** and pays out as platform-funded bonuses (never clawed from fare).

## 4. Architecture — cheap analytics, no heavy stack
The founder's instinct to avoid premature infra applies here.
- **Source of truth = the immutable ledger + `trip_events`.** No new event pipeline.
- **Read models via nightly (and near-real-time for "today") rollups:** small summary tables / materialized views (`driver_daily_stats`, `driver_zone_demand`) refreshed by a scheduled job — **not** a streaming analytics cluster. Redis holds the live "today" counters and the demand heatmap cells.
- **Heatmap** reuses the same geohash supply/demand signal the pricing engine computes ([05 §5.2](05-technical-architecture.md)) — one signal, two consumers (surge + driver guidance).
- **Privacy/audit:** driver analytics are the driver's own data; staff access to it is role-gated + audit-logged like everything else ([05 §5.4](05-technical-architecture.md)).

## 5. Data model additions (minimal)
- **`driver_daily_stats`** (driver_id, date, jobs, online_secs, gross, commission, fund, net, tips, cash_collected, cancels, avg_rating) — rollup, not source of truth.
- **`driver_zone_demand`** (geohash, window, open_requests, idle_drivers) — ephemeral, Redis-backed, persisted for trend history.
- Incentive progress derives from `campaigns` + ledger; nothing new required.

## 6. Build phase
- **Phase 1:** per-job net + live day total + 12h cap (drivers won't drive blind).
- **Phase 2:** weekly summaries, heatmap, quality trends, quests (tie to campaigns), statements.
- **Phase 4:** predictive hotspots, earnings goals, richer coaching. See [06](06-build-plan.md).

➡️ Related: [08 — Delivery System](08-delivery-system.md) · [09 — Notifications & Referrals](09-notifications-and-referrals.md) · [11 — Trust, Safety, Ratings & SOS](11-trust-safety-ratings-sos.md)
