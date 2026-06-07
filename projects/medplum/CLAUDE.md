# Medplum — Agent Guide

Node 22 / TypeScript / npm workspaces + Turborepo monorepo with PostgreSQL and Redis.

## Runtime environment

| What | Value |
|------|-------|
| Runtime | Node 22 (Alpine) |
| Package manager | npm (not pnpm — `packageManager: npm@10.x` in root `package.json`) |
| PostgreSQL | `postgres:5432` — user `medplum`, password `medplum`, db `medplum` |
| Redis | `redis:6379` |
| Workspace | `/workspace` |
| Results / logs | `/sandbox/results/logs/` |

All env vars (`POSTGRES_HOST`, `POSTGRES_PORT`, `MEDPLUM_DATABASE_*`, `REDIS_URL`, etc.) are pre-set in the worker container. Do not re-export them.

## Standard workflow

```
EXEC install    npm install
EXEC seed-db    docker exec ${RUN_ID}-medplum-postgres psql -U medplum -c "CREATE DATABASE medplum_test; CREATE ROLE medplum_test_readonly LOGIN PASSWORD 'medplum_test_readonly';" || true
EXEC test-seed  npm run test:seed --workspace=packages/server
EXEC build      sh -c 'NODE_OPTIONS=--max-old-space-size=1800 npx turbo run build --filter=@medplum/server...'
EXEC test       npx turbo run test --filter=@medplum/server -- --maxWorkers=2
EXEC start-server  sh -c 'node -e "import(\"/workspace/packages/server/dist/index.js\").then(m=>(m.runFromCli||m.default)()" &'
HEALTHCHECK     http://<worker-container>:8103/healthcheck
DONE
```

Labels `build` and `test` are special — supervisor records their exit codes in `result.json`.

### Why each step matters

- **seed-db**: creates `medplum_test` database and readonly role. Jest's `loadTestConfig()` targets this DB. Use `|| true` — command is idempotent.
- **test-seed**: runs `seed.test.ts` which applies migrations and seeds `medplum_test`. Must run before `test`.
- **build**: `--filter=@medplum/server...` — trailing `...` required to build the full dependency chain, not just the server package. `NODE_OPTIONS=--max-old-space-size=1800` prevents tsc OOM (~1.8 GB peak heap).
- **test**: `--maxWorkers=2` — parallel workers with shorter lifetimes prevent PostgreSQL connection exhaustion and peak memory accumulation.
- **start-server**: `packages/server/dist/index.js` guards its entrypoint with `if (import.meta.main)` — a Deno/Bun idiom Node.js never sets. Call `runFromCli()` directly via dynamic import.

## Health endpoint

`GET /healthcheck` → HTTP 200 with `{"postgres": true, "redis": true}`  
Default port: **8103**

## Key files to inspect

| File | Purpose |
|------|---------|
| `package.json` (root) | Workspace list, `packageManager` field |
| `packages/server/package.json` | Server-specific scripts and deps |
| `turbo.json` | Build pipeline graph |
| `.env.example` (if present) | Required config keys |

## Known issues

| Issue | Cause | Action |
|-------|-------|--------|
| `src/index.test.ts` — 4 tests fail | Pre-existing upstream bug: `DefaultQueueRegistry` singleton throws on second `initApp()` call | Ignore — not fixable in sandbox |
| Auth tests fail with "Missing googleClientId" | Config validator rejects empty string | Set placeholder: `MEDPLUM_GOOGLE_CLIENT_ID=sandbox-google-client-id` |
| `recaptcha`-gated tests skip/fail | `recaptchaSiteKey` empty | Set placeholder: `MEDPLUM_RECAPTCHA_SITE_KEY=sandbox-recaptcha-key` |
| Jest flag error: `testPathPattern` | Renamed in this Jest version | Use `--testPathPatterns` (plural) |

## Network-blocked domains

These domains are blocked by the sandbox firewall. Ask the user to whitelist them before running affected test suites:

```
api.pwnedpasswords.com, haveibeenpwned.com
www.googleapis.com, accounts.google.com, www.google.com
extensions.duckdb.org
```

User command (run on host): `sbx policy allow network -g <domain>[,<domain>…]`

## Failure signals

| Exit code | Meaning |
|-----------|---------|
| 137 | Worker OOM — needs more memory or lower `--maxWorkers` |
| non-zero `test` | Tests failed — read `logs/test.log` |
| healthcheck ≠ 200 | Server didn't start — read `logs/start-server.log` |
| ECONNREFUSED to postgres | `POSTGRES_HOST` / `POSTGRES_PORT` not set or `seed-db` step was skipped |
