# Nerv — Agent Guide

Node.js / TypeScript / Redis web application.

## Runtime environment

| What | Value |
|------|-------|
| Runtime | Node 20 (Alpine) |
| Package manager | npm |
| Redis | `redis://redis:6379` (already running, healthy before `SANDBOX_READY`) |
| Workspace | `/workspace` |
| Results / logs | `/sandbox/results/logs/` |

## Standard workflow

```
EXEC install   npm install
EXEC build     npm run build
EXEC test      npm test
EXEC start-server  node dist/src/server.js &
HEALTHCHECK    http://<worker-container>:3000/health
DONE
```

Labels `build` and `test` are special — supervisor records their exit codes in `result.json`.

## Health endpoint

`GET /health` → HTTP 200  
Default port: **3000**  
Verify from inside worker: `curl -sf http://localhost:3000/health`

## Key files to inspect

| File | Purpose |
|------|---------|
| `package.json` | Canonical script names (build / test / start) |
| `tsconfig.json` | TypeScript output dir (default: `dist/`) |
| `.env.example` | Required env vars (if present) |

## Failure signals

| Exit code | Meaning |
|-----------|---------|
| 137 | Worker OOM — needs more memory or leaner build |
| non-zero `test` | Tests failed — read `logs/test.log` |
| healthcheck ≠ 200 | Server didn't start — read `logs/start-server.log` |

## Redis notes

- In-memory only, no persistence.
- Soft cap: 96 MB (`allkeys-lru` eviction).
- Cache misses after eviction are normal; they don't indicate a bug.
