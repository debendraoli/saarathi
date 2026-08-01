# Saarathi — Deep Research & Design Dossier

> **Project:** Saarathi (सारथी — "charioteer / companion") — a combined **ride-hailing + local delivery super app**.
> **Primary market:** Dang district, **Lumbini Province (Province 5)**, Nepal — cities of **Ghorahi** & **Tulsipur**, plus Lamahi / Deukhuri valley.
> **Founder context:** Solo founder, bootstrap-stage. Focus of this dossier: **market, regulation, flows, operations, and architecture/approach**.
> **Last updated:** 2026-06-09. Data is current as of this date.

---

## Why this dossier exists

You asked for deep, current research focused on **approach and flows** rather than code. This folder is the result — eight linked documents you can hand to a designer, a developer, a lawyer, or an investor and have them understand the whole picture.

The single most important finding shaping everything below:

> 🟢 **Nepal published its first-ever ride-hailing/delivery legal framework — the _Digital Mobility Service Operation Standards, 2082 (2026)_ — as a public-consultation draft in April 2026.** After ~9 years of legal vacuum, the rules are now concrete: fare caps, a **10% commission ceiling**, mandatory **Nepali-server hosting**, a **government central-system API integration**, QR vehicle stickers, SOS buttons, driver background checks, and an accident fund. This is a _defining_ constraint and a _first-mover_ opportunity. See [02-regulatory-compliance.md](02-regulatory-compliance.md).

---

## How to read this dossier

| # | Document | What it answers |
| --- | ---------- | ----------------- |
| 01 | [Market & Opportunity](01-market-opportunity.md) | Is there a market in Dang? Who are the competitors? What's the wedge? |
| 02 | [Regulatory & Compliance](02-regulatory-compliance.md) | What's legal? What licenses do I need? What does the 2082 standard require? |
| 03 | [User Flows & Journeys](03-user-flows.md) | How does a rider, driver, and delivery customer actually move through the app? |
| 04 | [Operational Procedures](04-operational-procedures.md) | Onboarding, dispatch, payments, support, trust & safety — the day-to-day engine. |
| 05 | [Technical Architecture](05-technical-architecture.md) | What to build, in what order, with what stack — compliance-aware, tuned to your Go/Rust background. |
| 06 | [Phased Build Plan](06-build-plan.md) | Milestone-gated plan for a solo founder + Claude, incl. the rides-first vs both-verticals decision. |
| 07 | [Financial & Unit-Economics Model](07-financial-model.md) | Per-trip P&L, break-even, capital need, and the super-app margin math. |
| 08 | [Local Delivery System](08-delivery-system.md) | Parcel → food → grocery on the same fleet; merchant tiers, order lifecycle, COD. |
| 09 | [Notifications & Referrals](09-notifications-and-referrals.md) | The notification delivery ladder (push→SMS fallback) and the fraud-hardened referral loops. |
| 10 | [Driver Experience & Analytics](10-driver-experience-and-analytics.md) | Real-time earnings clarity, demand heatmaps, quests, statements — transparency as retention. |
| 11 | [Trust, Safety, Ratings & SOS](11-trust-safety-ratings-sos.md) | Two-sided ratings, the report/grievance system, and offline-capable emergency SOS. |
| 12 | [Detailed Execution Build Plan](12-execution-roadmap.md) | Engineering roadmap: what's built, the epic backlog, sequencing, and out-of-the-box bets. |
| 13 | [Revenue, Credits & Bargaining](13-revenue-and-monetization.md) | Making money under the 10% cap: prepaid credits, subscription passes, and bounded fare bargaining. |
| 14 | [Partnership / Fleet Program](14-partnership-fleet-program.md) | Multi-tenant fleet partners (à la Yango/inDrive): partner RBAC, fleet driver management, fleet campaigns, and legal revenue-share. |

---

## The one-paragraph strategy (TL;DR)

Dang's two sub-metropolitan cities (Ghorahi, Tulsipur) are **not yet served by Pathao or inDrive**, which concentrate on Kathmandu, Pokhara, Chitwan, and the bigger Terai hubs (Butwal, Bhairahawa, Nepalgunj). That is the wedge: **win the home turf before the incumbents arrive.** Start with **two-wheeler ride-hailing + parcel/food delivery** (lowest cost, highest frequency, matches local vehicle mix), price under the government fare ceiling, keep commission at or below the legal 10%, settle drivers in **cash + Fonepay/eSewa/Khalti**, and design from day one to be **compliance-native** (Nepali hosting, DoTM API hooks, QR stickers, SOS). Expand city-by-city across Lumbini once the unit economics in Dang are proven.

---

## Why Saarathi is different — out of the box

Not a cheaper clone of Pathao/inDrive — a **compliance-native, low-tech-first, hyper-local** platform whose advantages are structural, not features to be copied:

1. **Legally-better driver economics.** ≥90% to the driver (10% cap) vs the ~20–30% global norm — and we make that transparent so drivers _believe_ it ([10](10-driver-experience-and-analytics.md)).
2. **Offline-tolerant everything.** Fares fall back to a haversine estimate, SOS falls back to SMS, notifications escalate push→SMS, pickups are landmark+call. Built for patchy rural data, which incumbents assume away ([08](08-delivery-system.md), [09](09-notifications-and-referrals.md), [11](11-trust-safety-ratings-sos.md)).
3. **One fleet, many jobs.** Rides + parcel + food on the same driver/dispatch/wallet/ledger — utilization is survival in a thin market ([08](08-delivery-system.md)).
4. **Merchant-light onboarding.** WhatsApp-assisted → Lite → App tiers get a tier-3 shop live in a day; national apps won't hand-hold a momo cart ([08 §4](08-delivery-system.md)).
5. **Local trust as a safety feature.** Real Ghorahi desk, Nepali/Tharu/Awadhi support, direct **Nepal Police (100)** SOS integration — "Dang ko aafnai app," not a distant brand ([11](11-trust-safety-ratings-sos.md)).
6. **Compliance & data sovereignty from day one.** Immutable shared ledger, DoTM hooks, in-country hosting/KYC — a moat that's painful to retrofit ([02](02-regulatory-compliance.md), [05](05-technical-architecture.md)).

---

## Key numbers at a glance (current data)

- **Digital payments in Nepal:** NPR **98.43 trillion** in FY 2024/25, **+71% YoY**. Fonepay crossed **1M+ QR transactions in a single day**. (See [04](04-operational-procedures.md).)
- **Legal commission ceiling:** **10%** of fare (app-only operators). 90% to driver.
- **Fare ceilings:** NPR **25/km** (two-wheeler), NPR **55/km** (four-wheeler), minimum 2 km base fare, up to **+20%** night/weather/wait.
- **Incumbents:** Pathao (super app, since 2018), inDrive (P2P bargaining), legacy Tootle (first mover, 2017).
- **Competitor coverage gap:** No major app currently lists **Ghorahi / Tulsipur / Dang** as a service city.

---

## Founder decisions — status

| Question | Status |
| ---------- | -------- |
| **Team/build model** | ✅ **Solo + Claude.** Backend = **Rust microservices**; apps = **Flutter (Android + iOS at launch)** — mobile is the key risk. See [05 §3](05-technical-architecture.md). |
| **Launch vertical** | ✅ **Rides-first**, delivery as Phase 3 — architecture stays super-app-ready. See [06 §0](06-build-plan.md). |
| **Admin dashboard** | ✅ **In scope, advanced.** Driver verification workflow, RBAC (Super Admin/Admin/Analyst…), live tracking, live fee config + auto dynamic pricing (legally clamped) — **React/Next.js**. See [05 §5](05-technical-architecture.md). |
| **In-app comms** | ✅ **Chat + P2P voice/video calls** (WebRTC + self-hosted TURN), number-masked. See [05 §6](05-technical-architecture.md). |
| **Maps / hosting** | ✅ **OSM + self-hosted Valhalla** (cost) on a **Nepal-based** host (legal). See [05 §3](05-technical-architecture.md). |
| **DoTM API** | ⚠️ **Not released yet** — build connector as a stub behind an adapter; integrate when available. See [05 §11](05-technical-architecture.md). |
| **Legal entity / permit** | ✅ **Underway** (per founder). Keep the [02 §6](02-regulatory-compliance.md) checklist moving in parallel. |
| **Two-wheeler vs four-wheeler first** | ⏳ Recommended **two-wheeler first** (cheapest supply, lowest fare tier). Confirm via field interviews. |
| **Cash vs digital settlement** | ⏳ Design **cash-first, digital-nudged**; validate local driver wallet comfort. |

> Still to validate (field work): realized avg fare, trips/driver/day, insurance premium per trip, and digital-vs-cash split — these drive the whole model in [07](07-financial-model.md).

---

## Sources (accessed 2026-06-09)

- _Kathmandu Post_ — "Nepal moves to regulate ride-sharing, ride-hailing after nearly a decade" (Apr 24, 2026).
- _Ratopati (English)_ — "Nepal Government Introduces First Comprehensive Legal Framework for Ride-Sharing Services" (Apr 22, 2026).
- _Nepal Auto Trader_ — "New ride-sharing law in Nepal explained" (2026).
- _Simpaisa_ — "Nepal's Digital Payment Boom: 2025 Market Landscape" (Dec 2025).
- _MEA Tech Watch_ — "Nepal's Digital Payment Revolution" (Oct 2025).
- Wikipedia — Pathao, inDrive (current revisions, 2026).
- _eKantipur_ — "Legislate on ride sharing: Supreme Court" (Jan 2025).

> ⚠️ **Verification note:** Figures and rules above are drawn from public reporting on a **draft** regulation under consultation. Before incorporating or signing contracts, confirm the **final gazetted text** of the 2082 standard with the Department of Transport Management and a Nepali transport/fintech lawyer.
