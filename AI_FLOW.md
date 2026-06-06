# AI Agent Flow Log — Medplum Sandbox Validation

This document records what the AI agent discovered autonomously during the Medplum sandbox validation run, where the user had to intervene, and what operational lessons were acknowledged afterward.

---

## What the AI Figured Out Autonomously

### Repo and Stack Discovery

- Detected npm (not pnpm) as the package manager from `"packageManager": "npm@10.9.8"` in the root `package.json`.
- Identified the monorepo structure (npm workspaces + Turborepo) and the correct build invocation: `turbo run build --filter=@medplum/server...` — the trailing `...` is required to build the full dependency chain, not just the server package.
- Discovered that `tsc` peaks at ~1.8 GB heap and set `NODE_OPTIONS=--max-old-space-size=1800` accordingly for the build step.

### Server Start Shim

- Found that `packages/server/dist/index.js` guards its entrypoint with `if (import.meta.main)` — a Deno/Bun idiom. Node.js never sets `import.meta.main`, so the built server binary never starts.
- Created a `dist/start.mjs` wrapper to call the server's `runFromCli()` export directly. This was inferred by reading the compiled output, not from any docs.

### Database Wiring

- Discovered that Jest's `loadTestConfig()` reads `POSTGRES_HOST` and `POSTGRES_PORT` environment variables (falling back to `localhost`, which causes ECONNREFUSED inside the container). Added these to the worker's docker-compose environment.
- Found that tests target the `medplum_test` database, not `medplum`. Created `medplum_test` and the `medplum_test_readonly` role via `docker exec psql` before tests run.
- Identified that post-seed grants (`GRANT SELECT ON ALL TABLES IN SCHEMA public TO medplum_test_readonly`) were needed because the role is created before the schema tables exist.

### Schema Setup — `npm run migrate` vs `npm run test:seed`

- Initially tried `npm run migrate` to apply the schema to `medplum_test`. This failed with ECONNREFUSED to `127.0.0.1:5432`.
- Fetched `src/migrations/migrate-main.ts` from GitHub and discovered it hardcodes `host: 'localhost'` and is a **migration file generator** (it creates new TypeScript migration files for developers), not a schema applier.
- Identified `npm run test:seed` (which runs `seed.test.ts`) as the correct mechanism: it overrides `runMigrations=true` and calls `initAppServices()`, which creates the full schema and seed data in `medplum_test`.

### Missing System Dependency

- `oauth/cert.test.ts` failed with `/bin/sh: openssl: not found`. The Alpine-based worker image did not include OpenSSL.
- Added `openssl` to the `apk add` line in the worker Dockerfile.

### Jest Flag Rename

- Tests failed immediately with: `Option "testPathPattern" was replaced by "--testPathPatterns"`. The `--` plural form is required in the version of Jest used by Medplum. Corrected the flag.


### Network-Blocked Suites

- Identified all domains blocked by the sandbox firewall by running targeted test suites and reading error output: `api.pwnedpasswords.com`, `haveibeenpwned.com`, `www.googleapis.com`, `accounts.google.com`, `www.google.com`, `extensions.duckdb.org`.
- Reported these to the user for whitelisting.

### Pre-existing Medplum Bug (`index.test.ts`)

- `src/index.test.ts` consistently fails with "Queue DispatchQueue already registered" across all runs.
- Root cause: `DefaultQueueRegistry` is a global singleton in `src/workers/utils.ts`. When `initApp()` is called more than once in the same Jest worker process, the second call throws. This is a test isolation bug in the upstream medplum repo, not a sandbox issue.
- The AI identified the call stack, located the throw site (`utils.ts:149`), and confirmed it is pre-existing and not fixable within the sandbox.

---

## Where the User Intervened

### Node Version — Node 20 vs Node 22

The AI set up the worker with Node 20 and did not identify the Node 22 requirement on its own. The user pointed out that medplum requires Node 22. After switching to `node:22-alpine` in the worker Dockerfile, runtime errors (`Promise.withResolvers`, native `WebSocket` global) that had been failing silently resolved.

### Placeholder Credentials for Auth Tests

`auth/google.test.ts` and `auth/newuser.test.ts` were failing and the AI concluded that real Google OAuth and reCAPTCHA credentials were required to make them pass. The user challenged this, suggesting that placeholder/mock values should be sufficient for tests.

The AI then re-examined the test code and found the user was right:
- `auth/google.test.ts` mocks `jose`'s `jwtVerify` — no real Google JWT is needed.
- Tests use `getConfig().googleClientId` to populate request bodies. An **empty string** fails the server's `notEmpty()` validator before the mock intercepts, returning "Missing googleClientId".
- `auth/newuser.test.ts` tests recaptcha-rejection paths that only activate when `recaptchaSiteKey` is non-empty.

Fix: replaced empty strings with non-empty placeholder values (`"sandbox-google-client-id"`, etc.) in the config. Both suites passed.

### OOM Debugging — PostgreSQL Memory Limits

During test runs, Jest workers were being OOM-killed. The AI escalated memory in increments:
- Started with `512m` PostgreSQL memory limit and 1 Jest worker (`--maxWorkers=1`).
- Bumped to 1 GB, then 2 GB, then 3 GB — workers were still killed under sustained test load.

The user suggested bumping to 4 GB. The container was OOM-killed when it reached 2.4 GB of actual usage, confirming memory alone was not the right lever.

The user then suggested increasing the Jest worker count (`--maxWorkers=2`). This was the fix: multiple workers process test suites in parallel shorter-lived processes with better cleanup, preventing peak memory accumulation. The combination of 1–2 GB PostgreSQL memory and `--maxWorkers=2` became stable.

### Domain Whitelisting

The AI reported the blocked domains; the user ran the whitelist commands on the host:

```bash
sbx policy allow network -g api.pwnedpasswords.com,haveibeenpwned.com
sbx policy allow network -g www.googleapis.com,accounts.google.com,www.google.com
sbx policy allow network -g extensions.duckdb.org
```

### CLAUDE.md Operational Notes

After noticing inefficiencies during the session, the user added two operational constraints to `CLAUDE.md`:

- **No `.git` scanning** — the `.git` directory contains no useful information for this project; scanning it wastes tool calls.
- **Bash output size discipline** — pipe Bash output through `head`, `tail`, or `grep` to keep results small. Never `cat` large files; use the `Read` tool with `offset`/`limit` instead. (Prompted by a session where raw Bash output consumed ~28% of the context window.)

---

## Final Test Results

After all fixes (both autonomous and user-assisted):

| Metric | Result |
|--------|--------|
| Test suites | 237 / 238 pass |
| Tests | ~3570+ pass |
| Remaining failure | `src/index.test.ts` — 4 tests, pre-existing upstream bug |
| Build | Success |
| Healthcheck | HTTP 200, `postgres: true`, `redis: true` |

The single remaining failure is in the upstream medplum repository and is not fixable within the sandbox.
