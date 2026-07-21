# 07 — Financial & Unit-Economics Model

> Scope: A bottom-up unit-economics model for Saarathi in Dang, built on the **legal caps** from the 2082 standard. All figures are **NPR** unless noted (≈ **USD 1 = NPR 134**, mid-2026).

> ⚠️ **These are planning assumptions, not forecasts.** Every input is a knob — validate with the field interviews in [01 §7](01-market-opportunity.md). "Periods" below are **modeling stages tied to the build gates in [06](06-build-plan.md)**, not date commitments.

---

## 1. The hard constraint that shapes all economics

The 2082 standard **caps your commission at 10%** and your fares at **NPR 25/km (2-wheeler)** / **NPR 55/km (4-wheeler)**. So:

$$\text{Platform revenue per trip} = 0.10 \times \text{fare} \quad\text{(at most)}$$

You **cannot** raise take-rate to fix bad economics. Your only levers are:

1. **Volume** (more trips), 2. **Utilization** (more jobs per driver — rides *and* delivery), 3. **Digital-payment mix** (lower cash-handling friction), 4. **Cost discipline** (the 10% must cover opex *and* mandatory insurance/SSF).

> 💡 This single constraint is the entire financial argument for the super app: with take-rate fixed, **jobs-per-driver-per-day is the master variable.**

---

## 2. Per-trip unit economics (two-wheeler base case)

**Assumptions (editable):**

| Input | Value | Note |
|-------|-------|------|
| Avg ride distance | 3.5 km | Intra-city Ghorahi/Tulsipur |
| Avg fare | **NPR 90** | ≈ 3.5 km near the 25/km ceiling, incl. 2 km min base |
| Commission rate | 10% | Legal max |
| Accident-fund | 1% of fare | **Pass-through**, not revenue |
| Digital-payment share | 40% | Rest cash (Dang is cash-heavy early) |

**Per-trip P&L:**

| Line | NPR | Formula |
|------|-----|---------|
| Gross fare | 90.00 | — |
| **Platform commission (revenue)** | **9.00** | 10% × 90 |
| Accident-fund (pass-through) | (0.90) | 1% × 90 — remitted, not kept |
| Payment processing | (0.65) | 40% digital × 90 × ~1.8% |
| SMS/OTP + push (allocated) | (0.50) | per-login amortized |
| Maps/API (allocated) | (0.40) | per-request amortized |
| Support (allocated) | (1.00) | 24×7 cell amortized |
| Insurance + compliance admin (allocated) | (1.50) | life cover + SSF admin beyond the 1% fund |
| **Variable cost / trip** | **(4.05)** | sum of above |
| **Contribution margin / trip** | **≈ 4.95** | 9.00 − 4.05 → **~55% of commission** |

> 🔎 **Key insight:** of your NPR 9 commission, only **~NPR 5** survives as contribution — because mandatory **insurance/SSF/support** eat the rest. The 10% cap is *tight*; cost discipline is survival, not optional.

**Driver's side (why they stay):**

| Line | NPR/trip |
|------|----------|
| Driver share (90% − 1% fund) | ~80.10 |
| Fuel (allocated, ~3.5 km + deadhead) | ~(20) |
| **Driver net / trip** | **~60** |

At **10 trips/day × 26 days** → driver nets **~NPR 15,600/month** (before bike maintenance). That must beat local opportunity cost (irregular daily labor ~NPR 700–1,000/day) — it's **competitive but not lavish**, so earnings guarantees matter in early weeks.

---

## 3. Per-driver and fleet economics

$$\text{Daily platform contribution} = \text{trips/driver/day} \times \text{contribution/trip} \times \text{active drivers}$$

| Metric | Conservative | Base | Optimistic |
|--------|-------------|------|------------|
| Trips/driver/day | 8 | 10 | 14 |
| Active drivers | 60 | 100 | 150 |
| Daily trips | 480 | 1,000 | 2,100 |
| Daily GMV (fare) | 43,200 | 90,000 | 189,000 |
| Daily commission (rev) | 4,320 | 9,000 | 18,900 |
| Daily contribution | 2,376 | 4,950 | 10,395 |
| **Monthly contribution (×26)** | **61,776** | **128,700** | **270,270** |
| Monthly commission revenue | 112,320 | 234,000 | 491,400 |

---

## 4. Fixed costs (lean, solo + minimal ops)

| Item | NPR/month | Note |
|------|-----------|------|
| Founder stipend (survival) | 60,000 | You; keep lean while bootstrapping |
| Ops/support (1–2 part-time) | 40,000 | 24×7 grievance cell is legally required |
| Field onboarding/marketing | 20,000 | Driver/merchant acquisition, promos |
| Hosting/infra (Nepali) | 15,000 | VPS, maps/SMS base, backups |
| Legal/accounting/compliance | 15,000 | Permit renewal, audits, filings |
| **Total fixed** | **~150,000** | — |

---

## 5. Break-even

$$\text{Break-even trips/month} = \frac{\text{Fixed costs}}{\text{Contribution per trip}} = \frac{150{,}000}{4.95} \approx 30{,}300 \text{ trips/month}$$

≈ **1,165 trips/day** → roughly **100–120 active drivers at ~10 trips/day**, i.e. realistically **two cities (Ghorahi + Tulsipur) at healthy density.**

| Scenario | Monthly contribution | vs Fixed (150k) | Result |
|----------|---------------------|-----------------|--------|
| Conservative (60 drv, 8 trips) | 61,776 | −88,224 | 🔴 Loss |
| Base (100 drv, 10 trips) | 128,700 | −21,300 | 🟡 Near break-even |
| Optimistic (150 drv, 14 trips) | 270,270 | +120,270 | 🟢 Profit |

> 🟡 **Honest read:** rides-only in Dang is **marginal at base case** — you hover just under break-even. This is *expected* for a thin tier-3 market and is exactly why delivery (Section 7) is the path to durable margin, not a "nice-to-have."

---

## 6. Customer acquisition & payback

| Metric | Assumption | Note |
|--------|-----------|------|
| Rider CAC | NPR 150–300 | First-ride-free + referral credit |
| Driver CAC | NPR 500–1,500 | Field onboarding + earnings guarantee subsidy |
| Rider monthly contribution | ~NPR 50–100 | ~10–20 trips/mo × ~NPR 5 |
| **Rider payback** | **~2–4 months** | Acceptable for organic-heavy, referral-led growth |
| Driver payback | longer; justified by utilization | A driver doing rides **and** delivery pays back far faster |

> The earnings guarantee in early weeks is your **biggest controllable cost** — cap it, taper it as organic demand builds, and tie it to a minimum trips threshold to avoid gaming.

---

## 7. Why delivery transforms the model (the super-app math)

Delivery adds **revenue per existing driver-hour** with no new fleet. Model the **same 100 drivers** picking up **+4 delivery jobs/day** at ~NPR 12 contribution each (delivery fee, not the 10% ride cap):

| | Rides-only (base) | Rides + delivery |
|---|---|---|
| Jobs/driver/day | 10 | 14 (10 ride + 4 delivery) |
| Contribution/driver/day | ~49.50 | ~49.50 + (4 × 12) = **97.50** |
| Monthly contribution (100 drv ×26) | 128,700 | **253,500** |
| vs Fixed (150k) | −21,300 🟡 | **+103,500** 🟢 |

$$\text{Utilization uplift} = \frac{14 - 10}{10} = +40\% \text{ jobs} \Rightarrow \text{contribution roughly doubles}$$

> 🟢 **This is the whole thesis in numbers:** rides alone barely clear costs in Dang; **rides + delivery on one fleet** flips it firmly profitable. It also explains the sequencing in [06](06-build-plan.md) — prove rides liquidity first, then *stack* delivery onto the same drivers.

---

## 8. Capital requirement (bootstrap runway)

You're at roughly **−21k/month (base, rides-only)** until delivery lands or density rises. Budget runway for the pre-profit stretch:

| Bucket | One-time / early NPR | Note |
|--------|----------------------|------|
| Company/legal/permit setup | 100,000–200,000 | Registration, DoTM permit, legal drafting |
| Initial hosting + tooling | 50,000 | First months infra + dev tools |
| Earnings guarantees (launch) | 200,000–400,000 | Tapered driver subsidies, beta weeks |
| Launch marketing/promos | 100,000–200,000 | First-ride-free, referrals |
| Operating buffer (pre-break-even) | ~150,000–300,000 | ~2–4 months of the base-case gap |
| **Indicative seed need** | **~NPR 0.6M–1.3M** (≈ USD 4.5k–10k) | Bootstrappable for a lean solo founder |

> Building solo-with-Claude keeps your **biggest startup cost (engineering salaries) near zero** — your scarce resource is *time*, especially on mobile ([06 §0, 05 §3](06-build-plan.md)). That's the single best reason your bootstrap math works where a funded team's wouldn't.

---

## 9. Sensitivity — what moves the needle most

| Lever | Effect on contribution | Priority |
|-------|------------------------|----------|
| **+Jobs/driver/day** (add delivery) | 🔥🔥🔥 Highest — doubles margin | **#1** |
| **+Active drivers / density** | 🔥🔥 Scales linearly past break-even | #2 |
| **−Insurance/support cost** | 🔥🔥 Reclaims the eaten half of commission | #2 |
| **+Avg fare** (legal cap headroom) | 🔥 Limited — capped at 25/55 per km | #3 |
| **+Digital-payment share** | 🔥 Cuts cash handling, mild | #3 |
| **−Earnings guarantee** (taper) | 🔥 Reduces early burn | #3 |

> You **cannot** raise commission. So the model lives or dies on **utilization** and **insurance/ops cost control** — design for both from day one.

---

## 10. Numbers to validate before committing capital

- [ ] **Avg realized fare** in Ghorahi/Tulsipur (is NPR 90 real, or lower?).
- [ ] **Trips/driver/day** achievable at launch density (8? 10? 14?).
- [ ] **Insurance premium** per driver/trip — the biggest swing in the per-trip P&L.
- [ ] **Digital vs cash split** among real local riders.
- [ ] **Driver opportunity cost** — what daily net keeps them loyal.
- [ ] **Delivery contribution/job** — confirm merchants/customers will pay a delivery fee.

➡️ Back to [00 — Index](00-index.md) · See also [06 — Phased Build Plan](06-build-plan.md).
