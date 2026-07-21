# Saarathi (सारथी)

A compliance-native **ride-hailing + local-delivery super app** for **Dang district, Lumbini Province,
Nepal** (Ghorahi & Tulsipur). Launching **rides-first**.

- **Product & architecture dossier:** [`docs/research/`](docs/research/00-index.md)
- **Working context for contributors & AI:** [`AGENTS.md`](AGENTS.md)

## Quick start (backend)

```bash
cd backend
docker compose up -d        # Postgres+PostGIS, Redis, NATS
cargo build
cargo test
cargo run -p saarathi-auth  # starts the auth service on :8081
```

## Layout

| Path | What |
|------|------|
| `docs/research/` | Source-of-truth research & design dossier |
| `backend/crates/` | Shared Rust libraries (`saarathi-core`) |
| `backend/services/` | Coarse-grained microservices |

See [`AGENTS.md`](AGENTS.md) for the golden legal rules that the code must enforce.
