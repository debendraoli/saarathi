# Saarathi (सारथी)

A compliance-native **ride-hailing + local-delivery super app** for **Dang district, Lumbini Province,
Nepal** (Ghorahi & Tulsipur). Launching **rides-first**.

- **Product & architecture dossier:** [`docs/research/`](docs/research/00-index.md)
- **Working context for contributors & AI:** [`AGENTS.md`](AGENTS.md)

## Quick start (backend)

```bash
cd backend
cp .env.example .env        # then set JWT_SECRET: openssl rand -hex 32
docker compose up -d        # infra + every service, behind a gateway on :8080
cargo build
cargo test

# Or run a single service on the host against the compose infra:
cargo run -p saarathi-auth  # auth service on :8081 (runs migrations, seeds a dev super-admin)
cargo run -p saarathi-rides # rides service on :8082 (fares, trips, dispatch, campaigns, WS)
```

## Quick start (staff dashboard)

```bash
cd dashboard
cp .env.local.example .env.local
pnpm install
pnpm run dev                 # http://localhost:3000
```

Sign in with the dev super-admin phone `+9779800000000`. With `OTP_DEV_MODE=true` the
backend echoes the OTP in the response so you can log in without an SMS gateway.

## Layout

| Path | What |
|------|------|
| `docs/research/` | Source-of-truth research & design dossier |
| `backend/crates/` | Shared Rust libraries (`saarathi-core`) |
| `backend/services/auth/` | Identity, KYC verification, staff/admin RBAC & location |
| `backend/services/rides/` | Fares, trips, dispatch & matching, campaigns, realtime (WS/WebRTC) |
| `backend/services/merchant/` | Marketplace: merchants, menus, orders, delivery zones |
| `backend/services/` | Also: `payments`, `partners`, `campaigns`, `notify`, `places`, `routing` |
| `app/` | Flutter app — rider, driver & merchant surfaces |
| `dashboard/` | Next.js staff dashboard (driver verification, campaigns) |

See [`AGENTS.md`](AGENTS.md) for the golden legal rules that the code must enforce.
