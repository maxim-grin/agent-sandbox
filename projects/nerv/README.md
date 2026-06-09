# Nerv Stack

[Nerv](https://github.com/maxim-grin/nerv) is a Node.js / TypeScript web application backed by Redis.

## Stack

| Container | Image | Role |
|-----------|-------|------|
| `nerv-worker` | `sandbox-nerv-worker` (Node 20 Alpine) | Runs agent commands |
| `redis` | `redis:7-alpine` | In-memory only, no persistence |

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

./scripts/run_agent.sh /tmp/nerv-job.json
```

## Resource limits

| Container | Memory | CPU |
|-----------|--------|-----|
| nerv-worker | 1 GB | 2.0 |
| redis | 128 MB | 0.5 |

Redis enforces a soft cap of 96 MB (`allkeys-lru` eviction). Cache misses after eviction are normal.

## Build performance (warm images, cold npm cache)

| Phase | Time |
|-------|------|
| Build worker image (first time) | ~60s |
| Build worker image (cached) | <2s |
| Clone repo | ~5s |
| `npm install` | ~30s |
| `npm run build` | ~10s |
| `npm test` | ~15s |
| **Total** | **~65s** |

### Improvement options

- Mount a persistent volume at `/home/sandboxuser/.npm` to cache packages across runs.
- Pre-clone and pre-install into a warm worker pool.
