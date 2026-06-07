# Medplum Stack

[Medplum](https://github.com/medplum/medplum) is an open-source healthcare platform and FHIR server — a large TypeScript monorepo built with Node.js, PostgreSQL, and Redis.

## Stack

| Container | Image | Role |
|-----------|-------|------|
| `medplum-worker` | `ai-sandbox-medplum-worker` (Node 22 Alpine) | Runs agent commands |
| `postgres` | `postgres:16-alpine` | Per-run database, removed on teardown |
| `redis` | `redis:7-alpine` | BullMQ queue backend |

Node 22 is required — Medplum ≥5.0 uses `Promise.withResolvers` and the native `WebSocket` global, both absent in Node 20.

## Job spec

```json
{
  "project_type": "medplum",
  "repo_url": "https://github.com/medplum/medplum",
  "commit": "main"
}
```

## Quickstart

```bash
cat > /tmp/medplum-job.json <<'EOF'
{
  "project_type": "medplum",
  "repo_url": "https://github.com/medplum/medplum",
  "commit": "main"
}
EOF

./scripts/run_job.sh /tmp/medplum-job.json
```

## Resource limits

| Container | Memory | CPU |
|-----------|--------|-----|
| medplum-worker | 8 GB | 2.0 |
| postgres | 1 GB | 1.0 |
| redis | 192 MB | 0.5 |

Worker allocation is large to accommodate TypeScript monorepo compilation (~1.8 GB heap peak during `tsc`).

## Clean state

PostgreSQL uses a compose-managed volume (`pgdata`) — not declared external. `docker compose down -v` removes it automatically. No database state leaks between runs.

## Build performance (warm images, cold npm cache)

| Phase | Time |
|-------|------|
| Build worker image (first time) | ~90s |
| Build worker image (cached) | <2s |
| Clone repo | ~30s |
| `npm install` | ~120s |
| `turbo run build` | ~90s |
| Migrations + tests | ~90s |
| **Total** | **~5–7 min** |

### Improvement options

- Mount a persistent volume at `/tmp/.npm` to cache packages across runs.
- Pre-clone and pre-install into a warm worker pool.
- Route `npm install` through a local Verdaccio mirror.
