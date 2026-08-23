# Saarathi backend + dashboard Helm chart

Deploys all 9 backend services, Postgres/Redis/NATS, Valhalla, Pelias, and
the dashboard to a k8s cluster (built for Yeti Cloud, nothing cluster-specific
otherwise). See the deploy plan for the full design; this file is the quick
reference for actually running it.

## Trigger

`.github/workflows/deploy.yml` runs on a `v*` tag push or manual dispatch —
never on an ordinary push to `main`. It builds+pushes all 10 images to GHCR,
then `helm upgrade --install`s this chart.

## Required GitHub Actions secrets

| Secret | What it is |
| --- | --- |
| `KUBE_CONFIG` | base64-encoded kubeconfig for the Yeti Cloud cluster (`base64 -i kubeconfig.yaml \| pbcopy`) |
| `SAARATHI_DOMAIN` | your real domain, e.g. `saarathi.example` (becomes `api.<domain>` / `dashboard.<domain>`) |
| `SAARATHI_CERT_EMAIL` | email for the Let's Encrypt account (cert-manager `ClusterIssuer`) |
| `SAARATHI_DATABASE_URL` | full Postgres connection string, password included — must agree with `SAARATHI_POSTGRES_PASSWORD` |
| `SAARATHI_POSTGRES_PASSWORD` | the same password embedded in `SAARATHI_DATABASE_URL` |
| `SAARATHI_REDIS_URL` | e.g. `redis://redis:6379` |
| `SAARATHI_NATS_URL` | e.g. `nats://nats:4222` |
| `SAARATHI_JWT_SECRET` | `openssl rand -hex 32` |
| `SAARATHI_INTERNAL_SERVICE_SECRET` | `openssl rand -hex 32` |
| `SAARATHI_SPARROW_SMS_TOKEN` / `SAARATHI_SPARROW_SMS_FROM` | optional — blank disables the SMS fallback |
| `SAARATHI_TURN_SECRET` | optional — blank disables Coturn ICE creds |
| `SAARATHI_COTURN_EXTERNAL_IP` | the public IP of the node Coturn will land on (`coturn.nodeSelector` should pin it there) — required if Coturn is enabled, see the `coturn:` comment in values.yaml for why it can't just use a Service |
| `SAARATHI_FCM_SERVICE_ACCOUNT_JSON` | the full contents of the Firebase service-account JSON key (paste as-is) |

One-time, before the first deploy: cert-manager itself must already be
installed cluster-wide (its own upstream manifests, not part of this chart),
and Postgres needs its data pre-seeded via the existing schema migrations
(same `schema.sql`-per-service pattern used locally) — this chart provisions
the StatefulSet, not the schema.

## Local dry-run (no cluster required)

```bash
helm lint backend/deploy/helm/saarathi
helm template saarathi backend/deploy/helm/saarathi
```

## Manual install (operator, not CI)

```bash
cp backend/deploy/helm/saarathi/values-secret.example.yaml values-secret.yaml
# fill in values-secret.yaml with real values, then:
helm upgrade --install saarathi backend/deploy/helm/saarathi \
  -f values-secret.yaml \
  --set domain=saarathi.example \
  --set-file secrets.fcmServiceAccountJson=backend/secrets/fcm-service-account.json
```
