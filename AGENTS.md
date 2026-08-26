# AGENTS.md — Saarathi model context

> Read this first. This file is the working contract for any AI assistant (Copilot, Claude, etc.)
> and human contributor working in this repo. The **research dossier in [`docs/research/`](docs/research/00-index.md)
> is the source of truth** for product, market, regulation, and architecture decisions. When code and
> a research doc disagree, the research doc wins — or update the doc deliberately.

## What Saarathi is

A **compliance-native ride-hailing + local-delivery super app** for **Dang district, Lumbini Province,
Nepal** (Ghorahi, Tulsipur). Solo founder + AI. Launch **rides-first** (two-wheeler, Ghorahi); delivery
is a later phase on the same fleet. The job model is super-app-ready from day one.

## Golden rules (do not violate)

These come from the **Digital Mobility Service Operation Standards, 2082** and are legally load-bearing.
They must be enforced **server-side and are final** — never trust the client, never let config override them:

1. **Fare caps:** NPR **25/km** (two-wheeler), NPR **55/km** (four-wheeler). Minimum fare = 2 km equivalent.
2. **Surge cap:** night/weather/wait surcharge may never exceed **+20%** (multiplier ≤ 1.20).
3. **Commission cap:** platform takes **≤ 10%**; driver gets **≥ 90%**.
4. **Accident fund:** **1%** of every fare is levied to the accident fund.
5. **Pricing is config, not code.** Every knob is runtime-adjustable from the admin dashboard, but the
   engine hard-clamps to the caps above *after* applying any config. Config is **versioned + audited**.
6. **Data stays in Nepal.** Hosting and object storage are in-country. KYC docs encrypted at rest.
7. **Ledger is append-only + hash-chained.** No in-place edits, ever.
8. **DoTM reporting** goes through an adapter behind an outbox/retry pattern (the real API is not released
   yet — the connector is stubbed but the interface is stable).

If a change would weaken any of the above, stop and flag it.

## Domain invariants (not legal, but load-bearing)

**Job-type segregation.** There is **one dispatch queue** for both RIDE and DELIVERY, but each driver
declares **exactly one** job type at KYC (`drivers.service_types`, a single-element array constrained
to `{ride}` or `{delivery}` — never both, by DB `CHECK` and app validation; editable by staff from the
dashboard). Dispatch must honour that declaration *everywhere*, not just at match time:

- Candidate matching filters on the trip's `trip_type` against the driver's presence `job_types`.
- **So do the supply counts** — the rider app's "no drivers nearby" booking gate and the merchant's
  "no couriers nearby" warning each count only drivers eligible for *that* job type. A new caller of
  `dispatch::nearby_count` must pass the job type it actually means; getting this wrong doesn't fail
  loudly, it just quietly reports the wrong availability.
- Merchant orders reach couriers by being `delivery`-typed trips on this same queue. Do not add a
  second dispatcher for them.

See [05 §5.5.1–5.5.2](docs/research/05-technical-architecture.md) for the full design.

## Stack (confirmed)

| Layer | Choice |
|-------|--------|
| Backend | **Rust** microservices (`axum`, `tokio`, `sqlx`) in a Cargo workspace monorepo |
| Bus | **NATS JetStream** (event-driven; gRPC where needed) |
| DB | **PostgreSQL + PostGIS** (per-service schemas, shared instance early) |
| Cache/geo | **Redis** (H3-cell driver presence index, sessions, rate limits) |
| Object storage | MinIO / in-country S3-compatible |
| Mobile | **Flutter** (rider + driver, Android + iOS) — the #1 build risk |
| Admin | **React / Next.js** |
| Maps | **OSM + self-hosted Valhalla + Nominatim/Photon** |
| Payments | eSewa / Khalti / Fonepay / ConnectIPS (never build a wallet) |
| Infra | **Terraform + Kubernetes** (start small: k3s) on a Nepali host |

## Repo layout

```text
docs/research/     # Source-of-truth dossier (00-index.md is the map)
backend/           # Rust Cargo workspace (monorepo)
  crates/          # Shared libraries (saarathi-core: money, legal caps, pricing clamp,
                   #   authn extractors, H3 geo helpers, Pelias indexing)
  services/        # Coarse-grained services
    auth/          # Identity + KYC + location: OTP/JWT, driver verification, admin/staff
      migrations/  #   RBAC endpoints, PostGIS. Owns `users`/`drivers`/`vehicles`.
    rides/         # Trips, dispatch + matching, fare estimate, bidding, surge, campaigns,
                   #   realtime WS + WebRTC signaling. Also owns rider admin endpoints.
    merchant/      # Marketplace domain (food + grocery): merchants, menus, orders, zones
    payments/      # Top-ups, payouts, PSP callbacks
    partners/      # Fleet/partner domain (corporate tabs, partner-owned drivers)
    campaigns/     # Discount/bonus campaign management
    notify/        # Push/notification fan-out
    places/        # Community map contributions (user-submitted places)
    routing/       # Fare distance/duration only (Valhalla-backed)
  docker-compose.yml  # Local dev infra: Postgres+PostGIS, Redis, NATS, Valhalla, Pelias, tiles
dashboard/         # Next.js staff dashboard (driver verification, campaigns, RBAC-gated)
app/               # Flutter app — rider, driver, and merchant surfaces in one binary
```

> ⚠️ Domain ownership is not always where you'd guess: **rider** admin endpoints live in `rides`
> (`routes/insights.rs`), not `auth`, even though `auth` owns the `users` table. **Driver** admin
> endpoints live in `auth`. Grep before assuming.

## Running locally

```bash
# Backend — compose runs the infra *and* every service, behind a Traefik gateway on :8080
cd backend && cp .env.example .env   # then set JWT_SECRET (openssl rand -hex 32)
docker compose up -d                 # each service applies its own schema on boot
docker compose up -d --build auth    # rebuild + restart one service after a code change

# ...or run a single service on the host against compose infra:
cargo run -p saarathi-auth           # :8081, runs migrations + seeds a dev super-admin
cargo run -p saarathi-rides          # :8082, fare/trip/dispatch/campaign/WS APIs

# Dashboard
cd dashboard && cp .env.local.example .env.local && npm install
npm run dev                          # :3000 — sign in with +9779800000000 (OTP_DEV_MODE echoes the code)
```

> Test through the **gateway on :8080** (that's what the apps use). Internal routes (`/v1/internal/*`)
> are deliberately **not** gateway-routed — hit those on the service port with the `x-internal-secret` header.
>
> macOS note: `ring`/`cc` need the SDK path; `backend/.cargo/config.toml` sets `SDKROOT` so `cargo build` works.

## Conventions

- **Coarse services, not nano-services.** Start with a handful (auth, core-domain, dispatch, pricing,
  payments, compliance, admin). Split further only when a real scaling/isolation need appears.
- **Vertical slices over breadth.** One full flow working end-to-end beats ten half-built ones.
- **Money is never `f64`.** Use `rust_decimal::Decimal` (NPR). See `saarathi-core::money`.
- **Legal caps live in one place:** `saarathi-core::legal`. Never hardcode 25/55/0.10/0.20/0.01 elsewhere.
- **Parameterize the law** — caps are constants that clamp; rates within them are runtime config.
- **Security:** OWASP-aware. Parameterized queries only, validate at boundaries, rate-limit OTP, verify
  webhook signatures, idempotency keys on payment ops.
- **Errors:** `thiserror` for library errors, `anyhow` at binary boundaries.
- **Wire strings are not Dart/Rust identifiers.** The API speaks `snake_case` (`in_progress`, `no_driver`).
  Never match an enum by its language-level name against a wire value — use the explicit `fromWire`/
  `FromStr`-style mapper. (A `.name ==` comparison silently yielding `unknown` has already cost this repo
  a multi-session debugging spiral.)
- **Every staff mutation is audit-logged.** Any new admin endpoint writes an `audit_log` row (actor, action,
  entity, detail) alongside its `UPDATE` — this is DoTM defensibility, not bookkeeping. `auth` has an
  `audit` module; `rides`/`merchant` carry a small local `audit_record` helper for the same table.
- **Phone numbers are identity, not a profile field.** Phone is the OTP login key; no endpoint edits a
  rider's or driver's phone post-signup. Admin record-editing deliberately excludes it. (A merchant's
  `phone` is a business contact field — that one *is* editable.)
- **Tests:** unit-test the legal clamp and any money math exhaustively; contract-test the DoTM connector
  and payment webhooks (the riskiest external edges).

## Common commands

```bash
# from backend/
cargo build                 # build the whole workspace
cargo test                  # run all tests
cargo clippy --all-targets  # lint
cargo fmt                   # format
docker compose up -d        # start local Postgres/Redis/NATS
```

## Build order (see docs/research/06-build-plan.md)

Phase 0 (now): Rust scaffold + auth/OTP + core models + pricing engine w/ legal clamp + append-only
ledger + stubbed DoTM connector + admin skeleton. **Backend first** (founder strength; the apps need the
API contract to exist). Exit criteria: create a test driver, run a simulated trip end-to-end, see a
correct ledger entry + a stubbed DoTM report.
