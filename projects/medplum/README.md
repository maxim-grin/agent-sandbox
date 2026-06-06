# Medplum Stack

Worker stack for the [Medplum](https://github.com/medplum/medplum) open-source healthcare platform — a large TypeScript monorepo with Node.js, PostgreSQL, and Redis.

## Stack composition

| Container | Image | Role |
|-----------|-------|------|
| `medplum-worker` | `sandbox-medplum-worker` (Node 22, non-root) | Runs agent commands against the cloned workspace |
| `postgres` | `postgres:16-alpine` | Persistent per-run database (auto-removed on teardown) |
| `redis` | `redis:7-alpine` | BullMQ queue backend; in-memory with `noeviction` policy |

Medplum ≥5.0 requires Node ≥22.18.0 — this stack uses Node 22 instead of the default Node 20 used by other stacks.

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

## Example agent session

The agent reads `pnpm-workspace.yaml` and `package.json` inside `/workspace`, then drives the sandbox:

```
EXEC install npm install
EXIT_CODE install 0
EXEC build npx turbo run build --filter=@medplum/server...
EXIT_CODE build 0
EXEC test npx turbo run test --filter=@medplum/server
EXIT_CODE test 0
HEALTHCHECK http://localhost:8103/healthcheck
HEALTHCHECK_STATUS 200
DONE
```

`scripts/run_medplum_example.sh` is a harness simulation that does exactly this — it is not required behavior, just a demonstration of what an AI agent would do.

## PostgreSQL clean state

The PostgreSQL container uses a compose-managed volume (`pgdata`) that is **not** declared external. `docker compose down -v` removes it automatically — no database state leaks between runs.

## Resource limits

| Container | Memory | CPU |
|-----------|--------|-----|
| medplum-worker | 2 GB | 2.0 |
| postgres | 512 MB | 1.0 |
| redis | 192 MB | 0.5 |

Redis additionally enforces a soft cap of 128 MB (`--maxmemory 128mb --maxmemory-policy noeviction`). The worker has a larger memory allocation than other stacks to accommodate TypeScript monorepo compilation.

**When limits are hit:**

- **Worker OOM** — Docker kills the container (exit 137). The supervisor writes `result.json` with `"status": "failure"`. Treat exit 137 as an OOM signal.
- **CPU throttle** — Worker is slowed but not killed. Harness timeouts may fire.
- **Redis OOM** — With `noeviction`, write commands fail rather than silently dropping data; BullMQ job submissions will error.

## Build performance (cold start, warm images)

| Phase | Approximate time |
|-------|-----------------|
| Build Medplum worker image (first time) | ~90s |
| Build Medplum worker image (cached) | <2s |
| PostgreSQL init + healthcheck | ~10s |
| Clone Medplum repo | ~30s |
| `npm install` — 3000+ packages (no cache) | ~120s |
| `turbo run build --filter=@medplum/server...` | ~90s |
| Migrations + `npm test` in `packages/server` | ~90s |
| **Total (warm images, cold npm cache)** | **~5–7 min** |

### Improvement options

- Mount a persistent cache volume at `/tmp/.npm` (the non-root user writes here) to avoid re-downloading packages across runs.
- Pre-clone and pre-install into a warm worker pool so jobs skip straight to build/test.
- Route `npm install` through a local Verdaccio registry mirror to eliminate external network latency.
