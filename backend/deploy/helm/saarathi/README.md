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
| `SAARATHI_TURN_SECRET` | optional — blank disables Coturn ICE creds. Coturn itself runs on its own standalone instance, not in this cluster — see `scripts/coturn-setup.sh`; that script prints this value and the matching `services.rides.config.turnUrls` to set in `values.yaml` |
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

## Pelias bootstrap (one-time, after the first install)

The `helm upgrade --install` above brings up `pelias-opensearch` and
`pelias-api`, but the search index starts empty and the one-off import Jobs
aren't triggered automatically (they're slow — a few hundred MB of download
plus several minutes of processing — not something that should block or
re-run on every `helm upgrade`). Run these once, **in this order**, each
waiting for the previous to finish:

```bash
# 1. Wait for pelias-opensearch to be Ready (it installs the analysis-icu
#    plugin on first boot, which takes a little longer than a plain start):
kubectl -n saarathi rollout status statefulset/pelias-opensearch

# 2. Create the ES index/mapping — nothing else works until this succeeds:
kubectl apply -f <(helm template saarathi backend/deploy/helm/saarathi -s templates/pelias-schema-job.yaml)
kubectl -n saarathi wait --for=condition=complete job/pelias-schema --timeout=5m

# 3. WhosOnFirst (admin boundaries) — openstreetmap's import needs this
#    Job's *downloaded* sqlite files on disk (not the ES import to have
#    finished), but running it to completion first is simplest:
kubectl apply -f <(helm template saarathi backend/deploy/helm/saarathi -s templates/pelias-import-job.yaml -s templates/pelias-config-configmap.yaml)
# ^ applies both PVCs and both Jobs; if the openstreetmap Job starts before
#   whosonfirst has finished downloading, delete and re-apply it.
kubectl -n saarathi wait --for=condition=complete job/pelias-import-whosonfirst --timeout=10m
kubectl -n saarathi wait --for=condition=complete job/pelias-import-openstreetmap --timeout=30m
```

Re-running later (e.g. to refresh with newer OSM data) means deleting the
old Jobs first — Jobs are immutable once created:

```bash
kubectl -n saarathi delete job pelias-import-openstreetmap pelias-import-whosonfirst
```

## Map tiles bootstrap (one-time, after the first install)

Same idea as Pelias above — `tileserver-gl` needs a tileset built before it
has anything to serve, and building one is slow enough (a few hundred MB
download plus a few minutes of processing) that it shouldn't block or
re-run on every `helm upgrade`:

```bash
kubectl apply -f <(helm template saarathi backend/deploy/helm/saarathi -s templates/tiles-build-job.yaml)
kubectl -n saarathi wait --for=condition=complete job/tiles-build --timeout=20m
```

Then a normal `helm upgrade --install` rolls out `tileserver-gl` (it mounts
the same PVC the Job just wrote to). Point the app's
`SAARATHI_TILE_URL` build define at
`https://tiles.<domain>/styles/basic-preview/{z}/{x}/{y}.png`.

This same PVC is also what `martin` (martin-deployment.yaml) reads for the
app's vector-tile `MapView` — no separate bootstrap step needed for it, just
point the app's `SAARATHI_MARTIN_URL` build define at
`https://api.<domain>/tiles` (Martin has no public port of its own; it's
reached through the `api.<domain>` IngressRoute like every other service,
with the `/tiles` prefix stripped by Traefik before forwarding).

Without this, the app's `TileLayer` has no explicit `tileProvider` and
silently falls back to the public `tile.openstreetmap.org` — not meant for
app traffic, and the root cause of a persistent map-blur issue found and
fixed this same pass (see `saarathi_map_view.dart`'s `overrideFreshAge`
comment for the other half of that fix: the built-in tile cache was active
the whole time, it just never considered anything fresh because this
server doesn't send cache-freshness headers).

Re-running later (e.g. to refresh with newer OSM data) means deleting the
old Job first — Jobs are immutable once created:

```bash
kubectl -n saarathi delete job tiles-build
```

Everything above was verified end-to-end against a real cluster-equivalent
local stack (not just written from the upstream Pelias docs) — a few things
the upstream examples don't make obvious, all already fixed in these
templates:

- **This is Elasticsearch, not OpenSearch**, despite the `pelias-opensearch`
  resource name (kept for minimal diff — see `values.yaml`'s comment).
  OpenSearch — 1.x and 2.x, both tested — reports its own independent
  version string, which fails Pelias's hard-coded `>=7.4.2` Elasticsearch
  version check outright. There's no version of OpenSearch that satisfies it.
- `pelias-api`'s **real listen port is 3100**, not the `4000` `pelias.json`'s
  `api.port` field implies — it's ignored. The image name is also easy to
  get wrong: `pelias/openstreetmap`, not `pelias/openstreetmap-import` (that
  repository doesn't exist).
- Every Pelias import image's **default command is a bare shell** — a Job
  without an explicit `command` "succeeds" instantly having imported
  nothing, silently. Each needs `npm run download && npm start` (or `npm
  run create_index` for the schema tool).
- `pelias.json`'s `imports.openstreetmap` needs `datapath` /
  `leveldbpath` / `import: [{filename: ...}]` — older examples floating
  around use `dataFile` / `leveldbDir` (singular, different names), which
  this importer version's schema validator silently ignores in favor of its
  own (wrong) defaults instead of erroring.
