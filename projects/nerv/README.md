# Nerv Stack

Worker stack for the [Nerv](https://github.com/maxim-grin/nerv) project — a Node.js / TypeScript / Redis application.

## Stack composition

| Container | Image | Role |
|-----------|-------|------|
| `nerv-worker` | `sandbox-nerv-worker` (Node 20, non-root) | Runs agent commands against the cloned workspace |
| `redis` | `redis:7-alpine` | In-memory only; no persistence |

## Job spec

```json
{
  "project_type": "nerv",
  "repo_url": "https://github.com/maxim-grin/nerv",
  "commit": "main"
}
```

## Quickstart

```bash
cat > /tmp/nerv-job.json <<'EOF'
{
  "project_type": "nerv",
  "repo_url": "https://github.com/maxim-grin/nerv",
  "commit": "main"
}
EOF

./scripts/run_job.sh /tmp/nerv-job.json
```

## Example agent session

The agent reads `package.json` inside `/workspace`, then drives the sandbox:

```
EXEC install npm install
EXIT_CODE install 0
EXEC build npm run build
EXIT_CODE build 0
EXEC test npm test
EXIT_CODE test 0
HEALTHCHECK http://localhost:3000/health
HEALTHCHECK_STATUS 200
DONE
```

`examples/run_nerv_example.sh` is a harness simulation that does exactly this — it is not required behavior, just a demonstration of what an AI agent would do.

## Resource limits

| Container | Memory | CPU |
|-----------|--------|-----|
| nerv-worker | 1 GB | 2.0 |
| redis | 128 MB | 0.5 |

Redis additionally enforces a soft cap of 96 MB (`--maxmemory 96mb --maxmemory-policy allkeys-lru`).

**When limits are hit:**

- **Worker OOM** — Docker kills the container (exit 137). The supervisor writes `result.json` with `"status": "failure"`. Treat exit 137 as an OOM signal.
- **CPU throttle** — Worker is slowed but not killed. Harness timeouts may fire.
- **Redis OOM** — LRU eviction kicks in; application may see cache misses.

## Build performance (cold start, warm images)

| Phase | Approximate time |
|-------|-----------------|
| Build worker image (first time) | ~60s |
| Build worker image (cached) | <2s |
| Clone Nerv repo | ~5s |
| `npm install` (no cache) | ~30s |
| `npm run build` | ~10s |
| `npm test` | ~15s |
| **Total (warm images, cold npm cache)** | **~65s** |

### Improvement options

- Mount a persistent `npm-cache` volume at `/home/sandboxuser/.npm` to avoid re-downloading packages across runs.
- Pre-clone and pre-install into a warm worker pool so jobs skip straight to build/test.
