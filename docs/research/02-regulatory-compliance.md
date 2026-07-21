# 02 — Regulatory & Compliance

> Scope: What is legal, what licenses you need, and exactly what the **Digital Mobility Service Operation Standards, 2082 (2026)** require — plus payments and company-formation compliance.

> ⚠️ **This is research, not legal advice.** The 2082 standard was a **public-consultation draft** (April 2026). Confirm the final gazetted text and your specific obligations with the **Department of Transport Management (DoTM)** and a licensed Nepali transport/fintech lawyer before incorporating or signing driver/merchant contracts.

---

## 1. The headline: Nepal now regulates this sector

For ~9 years (2017–2026) ride-hailing operated in a **legal vacuum**. That ended:

- **Jan 2025** — Supreme Court directs the Government, Ministry of Industry/Commerce, and Department of Transport to build a legal structure for platforms like Pathao.
- **Apr 2026** — Ministry of Physical Infrastructure & Transport (via DoTM) publishes the **draft "Digital Mobility Service Operation Standards, 2082"** for public feedback (7–15 day consultation), aiming for rapid implementation.

**Definitions the draft establishes:**

- **Ride-sharing** — multiple passengers sharing a vehicle going the same direction (efficiency/cost/congestion). *Lighter obligations; exempt from some fees.*
- **Ride-hailing** — booking a vehicle (with/without driver) via a digital platform for private use, with integrated payment + tracking. *Vehicle treated as public transport.*
- **Digital mobility service** — the umbrella: any app/web service connecting passengers with vehicles on demand.

> Because Saarathi is an **on-demand booking app** (not carpooling), you will almost certainly fall under **ride-hailing / digital mobility service** — the heavier-obligation tier.

---

## 2. Operator (company) obligations under the 2082 draft

| Requirement | Detail | Design implication for Saarathi |
|-------------|--------|----------------------------------|
| **DoTM permit** | Register with DoTM, obtain an operating permit; **annual renewal**. | Budget time + recurring compliance cost. |
| **Central-system API integration** | App **must connect via API** to DoTM's central system for real-time ride tracking, fare calc, payment data. | Architect an **outbound compliance/reporting service** from day one ([05](05-technical-architecture.md)). |
| **Nepali-server hosting** | App **must be hosted on a Nepali server**; data security ensured. | Use a **Nepal-based data center / cloud region** or in-country VPS; affects your whole infra plan. |
| **Commission cap** | **Max 10%** of fare for app-only operators; **90% to driver**. | Revenue model must live within 10% ([01](01-market-opportunity.md)). |
| **Transparent in-app fare** | Fare must be shown clearly by distance, within Federal/Provincial ceilings. | Build a transparent fare estimator UI. |
| **QR vehicle sticker** | Each vehicle displays a DoTM-spec **QR sticker** (1-yr validity) holding permit no., vehicle + driver details, license validity. Operator produces/distributes; only passengers/police/officials can scan. | Build sticker issuance into driver onboarding + a verification scan endpoint. |
| **SOS button** | App must have a mandatory **SOS** that alerts the company control room + nearest police. | Safety subsystem is non-optional. |
| **24×7 grievance & rescue cell** | Staffed support + emergency response. | Plan a support roster even at small scale. |
| **Female-driver option** | App must let female passengers choose female drivers/riders where possible. | Add a gender-preference toggle + driver gender attribute. |
| **Insurance** | Life insurance for drivers and riders/passengers. | Partner with a Nepali insurer; bake premium into unit economics. |
| **Social Security Fund (SSF)** | Enroll all workers/drivers in SSF. | Onboarding must capture SSF enrollment. |
| **Accident Fund** | Deduct **1% of each fare**; compensation up to **NPR 1,000,000** (death/permanent disability), up to **NPR 100,000** (treatment). | Add a fund-deduction line to the fare ledger. |
| **Annual affiliation fee** | NPR **1,000** (2-wheeler) / **5,000** (4-wheeler) into Federal Consolidated Fund. **Pure ride-sharing exempt.** | Collect at sticker issuance; remit by end of Chaitra. |
| **Penalties** | DoTM may fine or cancel licenses for non-compliance. Zero-tolerance for harassment, unsafe/DUI driving, offline operation. | Compliance is existential, not optional. |

---

## 3. Driver & vehicle obligations

**Driver eligibility:**

- Minimum age **18**; must have held a license for **at least 1 year**.
- **Commercial driving license** required (per the directive's seven mandatory requirements).
- **Verified identity** + **clean background check**.
- Max **12 hours/day** logged into the app (anti-fatigue).
- **3-day orientation training** before service; **refresher every 4 months**.
- Misconduct → company must **digitally block & remove** the driver.

**The "seven mandatory driver requirements" (per reporting):**

1. Valid commercial driving license
2. Verified identity & registration
3. Clean background record
4. Registered commercial vehicle
5. Valid fitness certificate
6. Active insurance policy
7. Up-to-date tax clearance

**Vehicle standards:**

- Registration Bluebook must state **"Digital Mobility Service"** as purpose (ride-hailing); part-time drivers (≤4 rides/day) are exempt from purpose-spec but **still need the QR sticker**.
- Age **< 15 years** from manufacture.
- ICE vehicles must meet government pollution standards for public transport.
- **Two-wheeler:** helmets for driver + passenger; reflective jacket at night.
- **Four-wheeler:** dashcam, first-aid kit, fire extinguisher, central locking; boot **≥ 200 L**.
- **EVs:** minimum motor power specs (2-wheeler ≥1.5 kW; larger for 4-wheeler) + annual battery/high-voltage safety inspection.

> 🟡 **Driver-supply implication:** The **commercial-license + commercial-vehicle** requirement is the biggest friction. Many informal riders use private bikes/licenses. Expect a **short-term supply shock** (some drivers exit) but **long-term trust gain**. Your onboarding funnel ([04](04-operational-procedures.md)) must *guide* drivers through getting compliant, not just reject them.

---

## 4. Fare & commission rules (must-encode)

| Rule | Value |
|------|-------|
| Two-wheeler fare ceiling | NPR **25 / km** |
| Four-wheeler fare ceiling | NPR **55 / km** |
| Minimum base fare | Equivalent of **2 km** regardless of trip length |
| Surge / night / weather / wait | Up to **+20%** on base fare |
| Operator commission | **≤ 10%** of fare (app-only); 90% to driver |
| Accident-fund deduction | **1%** of each fare |

> These are **hard caps to encode in your pricing engine** as configurable, province-aware parameters (Federal vs Provincial governments may set specifics).

---

## 5. Payments & fintech compliance (NRB)

You will move money between riders, the platform, and drivers. That touches **Nepal Rastra Bank (NRB)** rules.

**Do NOT build your own wallet/PSP early.** Instead **integrate licensed providers**:

| Provider | Type | Use for Saarathi |
|----------|------|------------------|
| **eSewa** | First licensed PSP (2009), market leader | Customer payments, driver payouts |
| **Khalti / IME Khalti** | Wallet (Khalti + IME Pay merged) | Customer payments, rewards |
| **Fonepay** | P2M **QR interoperability backbone** (NEPALPAY QR), 1M+ QR/day | In-app QR acceptance, merchant settlement |
| **ConnectIPS** | NCHL bank-rails, real-time interbank | Bank transfers, driver bank payouts |
| **Namaste Pay** | NT + Rastriya Banijya Bank, **USSD/offline** | Rural/low-connectivity users |

**Compliance notes:**

- Use a **PSP/payment-gateway partner** so settlement, KYC, and escrow ride on *their* NRB license rather than yours.
- **Crypto is banned** in Nepal — do not touch it (IMF has flagged rising adoption *despite* the ban; stay clear).
- Keep **cash settlement** as a first-class path — much of Dang's driver/rider base is cash-comfortable.

---

## 6. Company formation & general compliance checklist

- [ ] **Register a Private Limited company** (Office of the Company Registrar).
- [ ] **PAN/VAT** registration (Inland Revenue Department).
- [ ] **DoTM operating permit** for digital mobility service (+ annual renewal).
- [ ] **API integration agreement** with DoTM central system.
- [ ] **Nepali-server / in-country hosting** arranged.
- [ ] **Insurance partner** (driver + passenger life cover) signed.
- [ ] **SSF enrollment** process for drivers.
- [ ] **Accident Fund** ledger + remittance process.
- [ ] **PSP/payment partner** agreements (eSewa/Khalti/Fonepay/ConnectIPS).
- [ ] **Data protection / privacy policy** (Nepal's privacy law + data-security clause in the standard).
- [ ] **Local-government coordination** in Ghorahi/Tulsipur sub-metros (route/parking norms, local taxes).
- [ ] **Terms of Service, driver contract, merchant contract** drafted under Labor Act 2074 + the 2082 standard.

---

## 7. Compliance-by-design principles (carry into architecture)

1. **Parameterize every legal number** (fare caps, commission %, fund %, fees) — they will change between the draft and the final law, and across provinces.
2. **Build the DoTM reporting/API connector as a core service**, not an afterthought.
3. **Host in Nepal** and keep personal data in-country.
4. **Make safety (SOS, QR verify, female-driver option) first-class**, not v2 features.
5. **Keep an immutable fare ledger** (fare, commission, accident-fund, payout) for audits.
6. **Design driver onboarding to upgrade informal drivers into compliant ones**, capturing license/fitness/insurance/tax docs.

➡️ Continue to [03 — User Flows & Journeys](03-user-flows.md).
