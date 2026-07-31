# Saarathi (सारथी)

A compliance-native **ride-hailing + local-delivery super app** for **Dang district, Lumbini Province,
Nepal** (Ghorahi & Tulsipur). Launching **rides-first**.

- **Product & architecture dossier:** [`docs/research/`](docs/research/00-index.md)
- **Working context for contributors & AI:** [`AGENTS.md`](AGENTS.md)

## Quick start (backend)

```bash
cd backend
cp .env.example .env        # then set JWT_SECRET: openssl rand -hex 32
docker compose up -d        # Postgres+PostGIS, Redis, NATS
cargo build
cargo test
cargo run -p saarathi-auth  # auth service on :8081 (runs migrations, seeds a dev super-admin)
```

## Quick start (staff dashboard)

```bash
cd dashboard
cp .env.local.example .env.local
npm install
npm run dev                 # http://localhost:3000
```

Sign in with the dev super-admin phone `+9779800000000`. With `OTP_DEV_MODE=true` the
backend echoes the OTP in the response so you can log in without an SMS gateway.

## Layout

| Path | What |
|------|------|
| `docs/research/` | Source-of-truth research & design dossier |
| `backend/crates/` | Shared Rust libraries (`saarathi-core`) |
| `backend/services/auth/` | Identity, KYC verification & location service |
| `dashboard/` | Next.js staff dashboard (driver verification) |

See [`AGENTS.md`](AGENTS.md) for the golden legal rules that the code must enforce.
