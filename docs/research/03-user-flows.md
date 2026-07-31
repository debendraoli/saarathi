# 03 — User Flows & Journeys

> Scope: How each actor moves through Saarathi end-to-end. This is the **"flows" focus** you asked for. Diagrams are Mermaid; states are explicit so they map directly to the backend state machines in [05](05-technical-architecture.md).

---

## 0. The actors

| Actor | Role |
|-------|------|
| **Rider (passenger)** | Books a person-trip (two-wheeler or car). |
| **Customer (delivery)** | Orders food/parcel/grocery to be delivered. |
| **Driver / Rider-partner** | Single fleet that fulfills **both** rides and deliveries. |
| **Merchant** | Restaurant/shop whose goods are delivered. |
| **Ops / Support** | Control room: dispatch oversight, SOS, grievances, KYC. |
| **DoTM (regulator)** | Receives compliance data via API; not an app user but a system actor. |

> **Core design principle:** one driver app, one dispatch engine, **two job types** (RIDE, DELIVERY). This is the structural reason a super app beats single-vertical here.

---

## 1. Top-level app map

```mermaid
flowchart TD
    Start([Open Saarathi]) --> Auth{Logged in?}
    Auth -- No --> Onboard[Phone OTP signup]
    Auth -- Yes --> Home[Home: choose service]
    Onboard --> Home
    Home --> R[🛵 Ride]
    Home --> F[🍔 Food]
    Home --> P[📦 Parcel]
    Home --> G[🛒 Grocery / Pharmacy]
    R --> RideFlow[Ride booking flow]
    F --> OrderFlow[Order flow]
    P --> ParcelFlow[Parcel flow]
    G --> OrderFlow
    RideFlow --> Track[Live tracking]
    OrderFlow --> Track
    ParcelFlow --> Track
    Track --> Pay[Pay: cash / wallet / QR]
    Pay --> Rate[Rate & tip]
    Rate --> Home
```

---

## 2. Rider (passenger) journey — ride-hailing

### 2.1 Happy-path flow

```mermaid
sequenceDiagram
    participant U as Rider
    participant A as Saarathi App
    participant D as Dispatch Engine
    participant Dr as Driver
    participant Pay as Payment/Ledger
    participant Gov as DoTM API

    U->>A: Set pickup + destination
    A->>D: Request fare estimate
    D-->>A: Fare (within NPR 25/km cap, 2km min base)
    U->>A: Confirm booking (+ female-driver toggle, payment method)
    A->>D: Create RIDE job (SEARCHING)
    D->>Dr: Offer job (nearest, online, compliant)
    Dr-->>D: Accept (ACCEPTED)
    D-->>A: Driver assigned + QR/vehicle details
    Dr->>U: Arrives (ARRIVED) -> verify QR sticker
    U->>Dr: Start trip (verify OTP)
    Note over Dr,U: ON_TRIP — live GPS tracking, SOS available
    Dr->>A: End trip (COMPLETED)
    A->>Pay: Compute fare, 10% commission, 1% accident fund
    U->>Pay: Pay (cash / wallet / QR)
    Pay->>Dr: Credit 90% (minus fund)
    A->>Gov: Report trip (tracking, fare, payment)
    U->>A: Rate driver + optional tip
```

### 2.2 Rider states

`SEARCHING → ASSIGNED → ARRIVED → ON_TRIP → COMPLETED → RATED`
Side-states: `NO_DRIVER_FOUND`, `CANCELLED_BY_RIDER`, `CANCELLED_BY_DRIVER`, `SOS_TRIGGERED`.

### 2.3 Key UX decisions (localized for Dang)

- **Pricing model:** Use **transparent metered fare** (distance × rate, capped) — *not* inDrive-style haggling — because it's simpler to keep within legal caps and builds trust. Optionally allow a small **tip**.
- **Map-light fallback:** Many pickups are landmark-based, not precise pins. Support **landmark + "share live location" + call driver**.
- **Female-driver toggle** surfaced at booking (legal requirement + trust differentiator).
- **QR verification:** Rider scans the vehicle's DoTM QR sticker to confirm driver/vehicle authenticity before boarding.
- **OTP start:** Trip starts only after rider gives the driver a one-time code → prevents wrong-pickup fraud.
- **Cash-first, digital-nudged:** Default cash but nudge wallet/QR with small incentives.

### 2.4 Edge cases to design for

- No driver found → auto-retry, widen radius, offer "notify me" or schedule.
- Rider cancels after assignment → grace window, then cancellation policy.
- GPS drift in dense bazaar areas → landmark confirmation + driver call.
- Connectivity drop mid-trip → cache trip state locally, reconcile on reconnect.

---

## 3. Driver / rider-partner journey (shared fleet)

### 3.1 Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Registered: Phone OTP + basic info
    Registered --> KYC_Pending: Upload license, bluebook, insurance, tax, PAN, driver photo, vehicle photo
    KYC_Pending --> Training: Background check passes
    KYC_Pending --> Rejected: Fails verification
    Training --> QR_Issued: 3-day orientation done
    QR_Issued --> Active: Vehicle QR sticker + SSF enrolled
    Active --> Online: Toggle "Go Online"
    Online --> OnJob: Accept RIDE or DELIVERY
    OnJob --> Online: Job completed
    Online --> Active: Toggle "Go Offline"
    Active --> Blocked: Misconduct / safety violation
    Active --> Refresher: Every 4 months
    Refresher --> Active
    Blocked --> [*]
```

### 3.2 The unified job offer (rides AND delivery on one screen)

```mermaid
flowchart TD
    Online([Driver ONLINE]) --> Offer{New job offer}
    Offer -->|RIDE| RJ[Pickup passenger<br/>verify OTP -> drop]
    Offer -->|FOOD/GROCERY| FJ[Go to merchant -> pickup -> deliver]
    Offer -->|PARCEL| PJ[Go to sender -> pickup -> deliver -> POD]
    RJ --> Done[Complete + auto-settle]
    FJ --> Done
    PJ --> Done
    Done --> Online
```

### 3.3 Driver UX decisions

- **One toggle, all jobs:** Driver opts into job types (rides, food, parcel) they'll accept → maximizes utilization in a thin market.
- **Earnings clarity:** Show **net** earning per job up front (after 10% + 1% fund) — drivers trust transparency, and inDrive won emerging markets partly on this.
- **12-hour cap enforcement:** App must lock new jobs after 12h online (legal anti-fatigue rule).
- **Compliance nudges:** Dashboard warns before license/fitness/insurance expiry, and before QR sticker's 1-year renewal.
- **Cash reconciliation:** For cash trips, driver owes platform the commission+fund → track a **driver balance wallet**; settle via wallet top-up or deduct from digital-trip earnings.

---

## 4. Delivery customer journey (food / grocery / pharmacy)

```mermaid
sequenceDiagram
    participant C as Customer
    participant A as App
    participant M as Merchant
    participant D as Dispatch
    participant Dr as Driver
    participant Pay as Payment

    C->>A: Browse merchant -> add items -> checkout
    A->>Pay: Authorize (cash on delivery / wallet / QR)
    A->>M: Send order (NEW)
    M-->>A: Accept + prep time (CONFIRMED -> PREPARING)
    A->>D: Request driver when food ~ready
    D->>Dr: Offer DELIVERY job
    Dr-->>D: Accept
    Dr->>M: Arrive + pickup (PICKED_UP)
    Note over Dr,C: EN_ROUTE — live tracking
    Dr->>C: Deliver (DELIVERED) + collect cash if COD
    A->>Pay: Settle merchant + driver + platform fee
    C->>A: Rate food + delivery
```

**Order states:** `CART → PLACED → CONFIRMED → PREPARING → READY → PICKED_UP → EN_ROUTE → DELIVERED → RATED` (+ `REJECTED_BY_MERCHANT`, `CANCELLED`, `FAILED_DELIVERY`).

**Delivery UX decisions:**

- **COD is king early** — design cash-on-delivery as the default, with reconciliation flowing into the driver balance wallet.
- **Merchant prep-time realism** — let merchants set/adjust prep time; dispatch the driver to arrive *as food is ready*, not before (avoids idle riders) and not late (avoids cold food).
- **Batching (later):** In dense bazaars, allow a rider to carry 2 nearby orders.
- **Parcel proof-of-delivery (POD):** photo + recipient name/OTP for parcels.

---

## 5. Merchant journey

```mermaid
flowchart LR
    Signup[Merchant signs up] --> Verify[KYC: PAN/VAT, location, menu]
    Verify --> Live[Listed in app]
    Live --> Order[Receives order on tablet/phone]
    Order --> AcceptDecline{Accept?}
    AcceptDecline -- Yes --> Prep[Prepare + mark ready]
    AcceptDecline -- No --> Reject[Auto-refund customer]
    Prep --> Handover[Hand to driver]
    Handover --> Settle[Daily/weekly settlement]
```

**Merchant decisions:**

- Start with a **lightweight merchant app / web dashboard** (even WhatsApp-assisted order confirmation in v0).
- **Menu + availability toggles** (out-of-stock is the #1 cause of cancellations).
- **Settlement cadence**: daily or weekly bank/wallet payout via ConnectIPS/Fonepay.

---

## 6. Payment & settlement flow (cross-cutting)

```mermaid
flowchart TD
    Trip[Trip / Order completes] --> Method{Payment method}
    Method -->|Cash| CashPath[Driver collects full amount]
    Method -->|Wallet/QR| DigPath[eSewa/Khalti/Fonepay charge]
    CashPath --> Owe[Driver owes platform:<br/>10% commission + 1% fund]
    DigPath --> Split[Auto-split:<br/>90% driver, 10% platform, 1% fund, merchant payout]
    Owe --> Bal[Deduct from driver balance wallet]
    Split --> Ledger[(Immutable fare ledger)]
    Bal --> Ledger
    Ledger --> Gov[Report to DoTM API]
    Ledger --> Insure[Accident fund + insurance accounting]
```

> The **immutable fare ledger** is the heart of compliance: every trip records fare, 10% commission, 1% accident fund, driver payout, payment method, and DoTM report status.

---

## 7. Safety & trust flow (legally mandated)

```mermaid
flowchart TD
    Trip([During any trip/delivery]) --> SOS{SOS pressed?}
    SOS -- Yes --> Alert[Alert control room + nearest police<br/>+ share live location/trip details]
    SOS -- No --> Normal[Continue]
    Alert --> Resolve[Ops resolves + logs incident]
    Normal --> End[Trip ends]
    End --> Grievance{Complaint filed?}
    Grievance -- Yes --> Cell[24x7 grievance cell -> investigate]
    Cell --> Action[Warn / digitally block driver / compensate]
```

**Safety features (all required by the 2082 standard):**

- **SOS button** → control room + nearest police.
- **QR sticker verification** before boarding.
- **Female-passenger → female-driver** option.
- **24×7 grievance & rescue cell.**
- **Zero-tolerance** auto-block for harassment/DUI/unsafe driving/offline rides.
- **Trip sharing** (share live trip with family).
- **In-app masked chat & call** — rider↔driver coordinate (esp. for landmark-based pickups) without sharing real phone numbers. (See [05 §6](05-technical-architecture.md).)

---

## 8. Flow-level design principles (carry into build)

1. **Cash-first, digital-nudged** across every vertical.
2. **One driver, one dispatch, many job types** — utilization is survival.
3. **Transparent metered pricing** within legal caps (not haggling).
4. **OTP + QR verification** to fight fraud and offline-ride leakage.
5. **Offline-tolerant** clients (cache + reconcile) for patchy connectivity.
6. **Compliance events are part of the flow**, not bolted on — every completed job emits a DoTM report + ledger entry.
7. **Landmark-friendly geolocation** — design for "near X temple," not just precise pins.

➡️ Continue to [04 — Operational Procedures](04-operational-procedures.md).
