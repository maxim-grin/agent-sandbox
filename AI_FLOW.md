# AI Agent Flow Log

---

## General AI Agent Behaviour Observations

### AI skips MVP and tries to make everything work at once

When given a new project, the AI tends to design and implement a full pipeline end-to-end (restore → build → unit tests → integration tests → start server → healthcheck) rather than starting from the smallest working slice and expanding. This makes early failures harder to interpret and wastes iteration time on steps that depend on earlier broken ones.

**Better approach:** Start from MVP (e.g. restore + build only), confirm it's green, then layer on tests and server health incrementally.

### AI works around blockers silently instead of surfacing them

When the AI hits an external dependency it can't reach (e.g. a CDN blocked by the sandbox firewall), its first instinct is to add a workaround (skipping the build step, mocking the call, etc.) rather than flagging the blocked domain clearly and asking the user to unblock it. This hides the real cause and may introduce unnecessary complexity.

**Better approach:** Surface blocked domains or missing external access explicitly ("cdnjs.cloudflare.com is blocked — should I request it be unblocked?") before attempting workarounds.

### AI jumps to implementation before plan is stable

When given a feature request, the AI tends to start writing files immediately rather than iterating on the design until it's correct. Plans presented too early are based on incomplete information and change when the user supplies missing context — wasting implementation work that then needs to be reverted.

In the OpenHands session (2026-06-09): the plan went through three rounds of correction before being approved — missing YAML in the user's example, wrong directory name (`projects/openhands/` → `agent/`), wrong compose strategy (separate file → integrate into existing files via profiles). If implementation had started after the first plan, all of it would have been wrong.

**Better approach:** Present plan, collect corrections, re-present, repeat until user explicitly approves. Only then implement. For architecture changes: update docs first, implement second — docs force precision and catch design errors cheaply.

---

## eShopOnWeb Stack Addition (2026-06-06)

Findings from researching and implementing the eShopOnWeb worker stack — an ASP.NET Core / C# / EF Core application. No live run yet; this section covers the research and design work.

### SDK Version — .NET 10 Required

The repo's `global.json` specifies:

```json
{ "sdk": { "version": "10.0.0", "rollForward": "latestFeature" } }
```

The worker image must use `mcr.microsoft.com/dotnet/sdk:10.0`, not an older LTS version. The `rollForward: latestFeature` setting means any 10.x feature band works, so the floating `10.0` tag is correct. Microsoft publishes multi-arch (arm64 + amd64) images for .NET SDK 10, so it runs on Apple Silicon without emulation.

### No SQL Server on ARM64 — In-Memory Database

SQL Server has no ARM64 Docker image. The user confirmed this constraint up front. eShopOnWeb supports an in-memory mode through a config flag checked in `src/Infrastructure/Dependencies.cs`:

```csharp
if (bool.Parse(configuration["UseOnlyInMemoryDatabase"]!))
{
    services.AddDbContext<CatalogContext>(c => c.UseInMemoryDatabase("Catalog"));
    services.AddDbContext<AppIdentityDbContext>(c => c.UseInMemoryDatabase("Identity"));
}
```

The env var name is `UseOnlyInMemoryDatabase` — not `UseInMemoryDatabase`. This was confirmed by fetching and reading `Dependencies.cs` directly from the repo. The stack has no database service container; just the single .NET worker.

### HTTPS Redirection — No-Op Without an HTTPS Port

`Program.cs` calls `app.UseHttpsRedirection()` unconditionally. However, ASP.NET Core's `HttpsRedirectionMiddleware` resolves the target port by checking (in order): `options.HttpsPort`, the `ASPNETCORE_HTTPS_PORT` env var, and then the server's bound addresses. Setting `ASPNETCORE_URLS=http://0.0.0.0:5000` (HTTP-only) leaves no HTTPS port resolvable, so the middleware is effectively a no-op and HTTP requests are served directly.

This avoids needing a self-signed certificate or a separate HTTPS binding inside the container.

### Health Check Routes

`Program.cs` registers two health check endpoints using tag-based predicates:

```csharp
app.MapHealthChecks("home_page_health_check", new HealthCheckOptions { Predicate = check => check.Tags.Contains("homePageHealthCheck") });
app.MapHealthChecks("api_health_check", new HealthCheckOptions { Predicate = check => check.Tags.Contains("apiHealthCheck") });
```

There is no `/health` or `/healthz` route. The harness probes `http://<worker>:5000/api_health_check`.

### Seed Data With In-Memory Database

`CatalogContextSeed.SeedAsync()` begins with:

```csharp
if (catalogContext.Database.IsSqlServer())
```

This returns `false` for in-memory databases, so the CSV-backed catalog seed is skipped. `Program.cs` calls `await app.SeedDatabaseAsync()` on startup, which still runs — it seeds identity/admin user data, which works with in-memory EF Core. For validation purposes (build, tests, health check) this is sufficient.

### Integration Tests Are Already In-Memory Capable

`tests/IntegrationTests/IntegrationTests.csproj` already references `Microsoft.EntityFrameworkCore.InMemory`. No additional configuration is needed for the integration test suite to run in the sandbox.

`tests/FunctionalTests` — excluded from the harness. Functional tests depend on Playwright or a live browser context and are not suitable for headless container execution.

### `--no-launch-profile` Matters for `dotnet run`

Without `--no-launch-profile`, `dotnet run` reads `src/Web/Properties/launchSettings.json` and uses whichever profile it selects by default. Those profiles typically bind to HTTPS (`https://localhost:5001`) or set their own URL, overriding `ASPNETCORE_URLS`. Passing `--no-launch-profile` ensures the container environment variables are respected.

### `AddAspireServiceDefaults()` Is Lightweight

`Program.cs` calls `builder.AddAspireServiceDefaults()`. This is a .NET Aspire helper that registers OpenTelemetry exporters and health checks. It does **not** require the Aspire orchestrator or a running Seq/OTLP collector. Telemetry export calls fail silently if no collector is available. The application starts and serves traffic normally.

---

## Medplum Sandbox Validation

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

---

## Sandbox Design Findings (2026-06-07)

### Per-project agent guide (`CLAUDE.md`) — tried and removed

Leaving the agent to infer the full workflow from raw manifests works, but wastes early tool calls on discovery that is identical every run for a known project. Per-project `CLAUDE.md` files were added to each `projects/<type>/` directory and copied into the workspace as `AGENT_GUIDE.md` before `SANDBOX_READY`.

This approach was later removed (2026-06-09) when the architecture shifted to OpenHands as the agent runtime. OpenHands reads repo manifests directly — the extra hint file adds overhead without changing what a capable LLM agent can infer. The harness example scripts already document the expected command sequence; a separate guide file duplicated that knowledge.

### Single-project mount

Early versions mounted the entire `projects/` directory into the supervisor. Each job only needs one stack's `docker-compose.yml` and `CLAUDE.md`. Mounting `projects/<type>/` as `/sandbox/project` instead:

- Reduces the blast radius if the supervisor is compromised — it cannot read other stacks' configs.
- Removes the possibility of the agent accidentally referencing a sibling project's files.
- Makes the isolation boundary explicit in the `docker run` invocation.

No supervisor code changes were required beyond updating the path constant (`PROJECTS` → `PROJECT_DIR`).

### Timeouts needed at every layer

Without explicit timeouts, a hung `npm install` or a test that deadlocks leaves the supervisor (and the whole run) blocked indefinitely. Three distinct limits cover the full lifecycle:

- **Per-step (`TIMEOUT_EXEC`, default 600s)** — wraps each `EXEC`'s `docker exec` call with `timeout(1)`. Exit code 124 is returned to the agent as the step's `EXIT_CODE`, so the harness can detect and abort rather than loop. Steps with code 124 appear in `result.json` with `"status": "failure"`.
- **Total job (`TIMEOUT_TOTAL`, default 1800s)** — a background watchdog fires SIGUSR1 to the supervisor after the whole-job limit. The supervisor calls `finish("timeout")` — same teardown path as normal failure, so `result.json` and logs are always written.
- **Stack startup (`TIMEOUT_STACK_HEALTHY`, default 120s)** — caps the wait for the worker container's Docker healthcheck; prevents the job from hanging if the image fails to start.

All three are configurable via `.env` at the repo root or shell environment, so individual stacks with slow builds (e.g. first-time .NET restore) can raise limits without touching supervisor code.

### Separate harness simulations from operational scripts

Example scripts that simulate an AI agent session (`run_<type>_example.sh`) were co-located with the runner scripts in `scripts/`. Mixing them creates ambiguity: a real agent scanning `scripts/` might treat the example scripts as part of the sandbox interface.

Moved to `examples/`. The `scripts/` directory now contains only `run_agent.sh`. The examples are human-readable demonstrations; they belong outside the operational surface.

### Agent should not see previous run history

`run_results/` is on the host filesystem and is not mounted into the worker container. This is intentional — agents get no access to prior run results.

Arguments for giving agents history were considered and rejected:

- **Stale failures mislead.** A failure from a previous commit may be fixed in the current one. The agent would waste time avoiding a non-issue.
- **Stale successes give false confidence.** A passing run on commit A says nothing about commit B.
- **Design intent.** The agent reads the repo's own manifests to decide commands. Prior run logs bypass that intent and add noise before the first tool call.
- **Context cost.** Even summary-level logs across 30+ runs consume significant context before any useful work starts.

**Exception worth considering:** a small structured `project_notes.json` passed at job start — recording *persistent* patterns that don't change between commits (e.g. "NuGet restore requires private feed auth", "test suite requires `openssl` in PATH"). This is signal, not history. It has not been implemented yet.

### `run_results/` organised by project, then run

Previously all run directories were flat under `run_results/<run-id>/`. Reorganised to `run_results/<project>/<run-id>/` so runs for different repos don't mix.

For harness mode, `project` = `project_type` from the job spec.  
For agent mode (`run_agent.sh`), `project` = last path segment of `repo_url` (`.git` stripped) — there is no `project_type` concept when OpenHands evaluates arbitrary repos.

---

## OpenHands Agent Mode (2026-06-09)

### Motivation

The harness simulation scripts (`examples/run_*_example.sh`) hard-code the command sequence for each known repo. That works as a demo but defeats the point of an AI agent sandbox — a real agent should figure out how to build and test an unknown repo without being told the steps.

OpenHands (headless LLM agent in a Docker container) replaces the scripted harness for the agent runner path. The agent reads workspace manifests, decides commands, executes the full pipeline, and writes a structured JSON report.

### No separate OpenHands compose file

First instinct was to add `projects/openhands/docker-compose.yml`. Rejected: OpenHands is not a project-specific worker stack — it needs to run alongside whichever project's data services (Redis, PostgreSQL, etc.) are required by the repo under test.

Solution: add OpenHands as a `profiles: [agent]` service inside each existing project's `docker-compose.yml`. Harness runs (`docker compose up -d`, no profile) don't start it. Agent runs (`--profile agent`) start data services + OpenHands together. One compose file per project, two modes.

### Prompt as file, not hardcoded YAML

Embedding the task prompt directly in `command:` in the compose YAML makes it hard to iterate on prompt wording without touching infrastructure files. Prompts live in `projects/<project_type>/prompt.txt` — one file per project type, containing stack-specific context and known quirks discovered during runs. Runner reads `projects/${PROJECT_TYPE}/prompt.txt`, exports as `TASK`, compose substitutes `${TASK}` into the OpenHands command. Change prompt → edit one file, no YAML diff.

### No Docker socket for OpenHands

OpenHands supports a Docker runtime (spawns a container for code execution) and a local runtime (runs commands inside the OpenHands container). The local runtime requires no Docker socket mount — OpenHands executes directly inside its own container. This is simpler and reduces the attack surface compared to giving OpenHands socket access.

Trade-off: local runtime means the runtime environment is whatever is in the `openhands/openhands:latest` image. OpenHands can install tools dynamically (via `apt`, `npm`, etc.) but cold installs add latency on each run.

### Result written by the agent, not the supervisor

In harness mode, the supervisor writes `result.json` by tracking `EXIT_CODE` responses and `HEALTHCHECK_STATUS`. In agent mode, there is no supervisor — OpenHands writes `result.json` directly to `/sandbox/results/` as the final step of its task. The prompt specifies the exact schema. The runner treats an absent or malformed `result.json` as a failure.

### `project_name` vs `project_type` in results path

Harness mode uses `project_type` (from job spec: `nerv`, `medplum`, `eshoponweb`). Agent mode derives `project_name` from `repo_url` (last segment, `.git` stripped). For `https://github.com/org/nerv.git` → `nerv`. This keeps result paths consistent with the actual repo being tested, regardless of which agent ran it.

---

## Harness Script Consolidation (2026-06-09)

### `run_job.sh` removed

`run_job.sh` was a wrapper that built images, created Docker resources, ran the supervisor, copied results, and tore down. The example scripts (`examples/run_*_example.sh`) already do all of this directly — they build images, create network/volumes, start the supervisor via `docker run -i`, send EXEC/HEALTHCHECK/DONE commands, copy results, and clean up. `run_job.sh` added a layer without adding capability.

Deleted. `scripts/` now contains only `run_agent.sh`. Harness mode was driven exclusively through example scripts.

---

## Per-Project Agent Prompts (2026-06-09)

### Single generic prompt replaced by per-project prompts

Initial implementation used one `agent/prompts/pipeline_task.txt` shared across all project types. The generic prompt told OpenHands to figure out build/test/start/healthcheck from repo manifests alone.

Problem: each project has non-obvious stack quirks that cause agent failures or wasted discovery cycles. A capable LLM can eventually find these by trial and error, but the sandbox has time limits and the failures are predictable — the same quirks appear on every run. Embedding known context in the prompt short-circuits dead ends without removing the agent's autonomy over actual commands.

Per-project prompts at `projects/<type>/prompt.txt` capture:
- Runtime version requirements (e.g. Node 22 not 20 for Medplum)
- Data service connection details already set in env (no discovery needed)
- Known setup steps not inferable from manifests (e.g. Medplum test database creation, `medplum_test_readonly` role, post-seed grants)
- Known entry-point quirks (e.g. Medplum's `import.meta.main` guard requiring a start shim)
- Correct health check routes (e.g. eShopOnWeb's `/api_health_check`, not `/health` or `/healthz`)
- Test suite constraints (e.g. exclude FunctionalTests for eShopOnWeb, use `--maxWorkers=2` for Medplum)

### No fallback on missing prompt

`run_agent.sh` errors immediately if `projects/${PROJECT_TYPE}/prompt.txt` does not exist. A silent fallback to a generic prompt would let a misconfigured run proceed with a worse-quality prompt, producing confusing results. Explicit failure forces a prompt to be written before the project type can be used.

### Prompts live inside the project directory

Prompt files are co-located with the project's `docker-compose.yml` and `worker/` under `projects/<type>/`. All project-specific artifacts in one place — adding a new stack means touching only that stack's directory (plus schema enum).

---

## Agent Mode: Resource Exhaustion and Security Hardening (2026-06-09)

### Host OOM in Agent Mode — Root Causes

Running the pipeline in agent mode with the nerv project exhausted host machine resources. Post-mortem identified four causes:

**1. OpenHands spawned inner sandbox containers via Docker socket (primary cause)**

The nerv `docker-compose.yml` gave OpenHands full Docker daemon access:

```yaml
volumes:
  - /var/run/docker.sock:/var/run/docker.sock
environment:
  - SANDBOX_USER_ID=0
  - SANDBOX_VOLUMES=${WORKSPACE_VOLUME}:/workspace
  - SANDBOX_ADDITIONAL_NETWORKS=${SANDBOX_NETWORK}
```

OpenHands uses the socket to create its own runtime sandbox container on the host daemon. That inner container has no resource limits — not governed by anything in the compose file. It is also outside the `cleanup()` trap scope, so if the script exits abnormally, the inner container leaks and continues consuming resources.

**2. No resource limits on the OpenHands container**

Worker: `mem_limit: 1g`, `cpus: 2.0`. Redis: `mem_limit: 128m`. OpenHands: no limits. The container could consume all available host RAM.

**3. No timeout on `docker wait`**

`run_agent.sh` calls `docker wait "$OPENHANDS_CONTAINER"` with no timeout. If the LLM loops (bad tool calls, retry storms, hallucinated commands), the run continues until the host dies.

**4. Inner containers not cleaned up on abnormal exit**

`cleanup()` tears down the compose stack, but OpenHands-spawned inner containers are managed by OpenHands internally. If the outer cleanup fires before OpenHands finishes, or the script exits abnormally, those containers stay running.

### Plan: Switch to OpenHands SDK (Removes Primary Cause)

The active plan (`PLAN.md`) switches from the `openhands --headless` CLI to a Python SDK runner. The SDK uses a local runtime — no Docker socket needed. This eliminates inner container spawning and the associated resource leaks and host escape vector.

The plan also adds:
- `mem_limit: 2g` / `cpus: 1.0` on the openhands service
- `timeout "${TIMEOUT_TOTAL:-1800}" docker wait` in `run_agent.sh` (reuses the same env var as the harness supervisor)

### Security Findings

The Docker socket removal fixes the most serious security issue, but analysis identified additional concerns.

**Not fixable — accept as design trade-offs:**

- `OPENHANDS_ALWAYS_APPROVE=true` is required for non-interactive headless execution. All agent tool calls (shell, file write, network) run without confirmation. Mitigated by network isolation.
- The LLM API key is readable inside the OpenHands container by any process running as the same user (`/proc/1/environ`). File-based secrets (below) hide it from `docker inspect` but not from container-internal reads. Mitigated by keeping the key low-value (Groq free-tier) and rotating after runs if needed.

**Fixable — captured in `PLAN.md` Step 3:**

| Issue | Fix |
|-------|-----|
| API key visible in `docker inspect` | Docker Compose file-based secret — write key to temp file, mount at `/run/secrets/groq_api_key`, runner reads from file, remove from `environment:` block |
| Worker and OpenHands on same external-routable network — worker (running untrusted repo code) can make arbitrary outbound calls | Make `sandbox` network `--internal` (no external routing); give OpenHands a second `llm-net` network for LLM API egress only. Worker and Redis stay on internal-only sandbox. |
| Unpinned `pip install openhands-ai` — supply chain risk | Pin to a specific version once Step 1 of the plan confirms the correct package |
| Unpinned `python:3.11-slim` base image | Pin to `python:3.11.9-slim` |
| OpenHands container runs as root (default for `python:3.11-slim`) | Pre-baked image (already the plan's alternative to pip-at-start) installs SDK as root, adds non-root user, runs as non-root. `user: nobody` inline doesn't work cleanly with pip-at-start. |
| Results volume writable by worker in agent mode | Worker doesn't write `result.json` in agent mode. Change mount to `results:/sandbox/results:ro` on the worker service. |

### `Dockerfile.openhands` Is Unused

`projects/nerv/Dockerfile.openhands` exists but is not referenced in `docker-compose.yml` — the compose file pulls `ghcr.io/all-hands-ai/openhands:latest` directly. Node.js installed in that Dockerfile has no effect. The file will be removed or repurposed when the SDK migration (pre-baked image path) is implemented.

### Plan: timeout env var source

The plan reuses `TIMEOUT_TOTAL` for `docker wait` timeout. That variable was previously set and documented in the supervisor — which is now deleted. `TIMEOUT_TOTAL` must be set in `.env` or the shell environment before calling `run_agent.sh`. The default of 1800s applies if unset.

---

## Harness Mode Removed (2026-06-09)

### Decision

Harness mode (EXEC/HEALTHCHECK/DONE protocol driven by example scripts) was removed entirely. Agent mode (`run_agent.sh` + OpenHands) is the only execution path going forward.

Harness mode was designed as a deterministic demo and debugging tool — a scripted stand-in while the agent runner was being built. Once the agent runner was functional and the goal shifted to evaluating unknown repos autonomously, the harness added no value. Maintaining two parallel execution paths (harness and agent) with separate supervisors, example scripts, and compose profiles introduced complexity without benefit.

### What was deleted

| Path | Contents |
|------|----------|
| `supervisor/` | Harness supervisor — `Dockerfile`, `entrypoint.sh`, `lib/capture.sh`, `lib/clone.sh`, `lib/exec.sh`, `lib/orchestrate.sh` (~330 lines total) |
| `examples/` | Three harness example scripts — `run_nerv_example.sh`, `run_medplum_example.sh`, `run_eshoponweb_example.sh` |

### What changed

- `projects/*/docker-compose.yml` — removed `profiles: [agent]` from the openhands service. With harness gone, there is no plain `docker compose up` path; `run_agent.sh` always starts the full stack including OpenHands. The profile guard was dead code.
- `scripts/run_agent.sh` — removed `--profile agent` from both `compose up` and `compose down` invocations.
- All compose file headers and worker Dockerfiles — updated stale comments referencing "the supervisor" to reference `run_agent.sh`.

### CLAUDE.md harness documentation

`CLAUDE.md` still contains harness mode documentation (EXEC protocol, workspace inspection table, harness failure interpretation). That section should be removed or replaced with agent-mode-only guidance in a follow-up update.

---

## Migration: opencode + Multistage Pipeline (2026-06-11)

### Decision: drop openhands, adopt opencode

openhands SDK integration worked but had two structural problems: (1) massive system prompt (~15k tokens) immediately exhausted Groq free-tier TPM on first request; (2) the custom `SSHRuntime` implementation was fragile — every openhands-ai version bump broke the internal API.

opencode is a purpose-built coding agent CLI with a stable HTTP server API (`opencode serve`). The HTTP API (`POST /session/:id/command`) is a versioned contract, not internal Python class introspection. No SDK to maintain.

### Decision: single container, no agent container

Previous architecture required a separate openhands container that SSHed into worker. With opencode running inside the worker, the agent container is eliminated entirely. `run_agent.sh` drives stages via `docker exec curl` — no inter-container networking needed for agent→worker comms.

Side effects: SSH keypair generation removed, no `cap_add: [SETUID, SETGID, SYS_CHROOT]` needed, no `Dockerfile.agent`, no `openhands_runner.py`.

### Decision: 4-stage pipeline with context isolation

Single monolithic prompt was the cause of both token bloat and poor result attribution — a failure could happen anywhere and the agent had to reason across the entire pipeline history.

Four focused stages (discovery → build → tests → run) each run as an opencode `subtask: true` command — isolated LLM context per stage. State passes through `/workspace/.pipeline/<stage>.json` files. Shell injection (`!cat`) pulls prior stage output into each prompt at invocation time.

Benefits: smaller per-stage token windows, per-stage cost tracking, clear failure attribution, stages can be re-run independently.

### Decision: TDD with mock LLM

`scripts/mock/llm_server.py` — OpenAI-compatible mock server returning canned responses. `MOCK=true` flag in `run_agent.sh` skips real clone and points `LLM_BASE_URL` at mock. Every stage is verified against mock before touching real Groq API. Eliminates API cost from iteration cycles and makes test runs deterministic.

### Decision: opencode serve HTTP API over CLI

`opencode run "<prompt>"` was the initial approach. Switched to `opencode serve` + HTTP API because:
- `POST /session/:id/command` is synchronous and returns structured JSON — no output parsing needed
- `GET /global/health` gives a reliable healthcheck endpoint
- `POST /session/:id/command { command: "tokenscope" }` integrates token tracking without any runner changes
- Sessions can be created/deleted explicitly — context lifecycle is under orchestrator control, not CLI process lifecycle

### Token tracking: tokenscope plugin

`@ramtinj95/opencode-tokenscope` npm plugin provides per-session token breakdown and cost calculation via `/tokenscope` command. Installed in worker image, called after each stage. Replaces openhands `state.metrics.accumulated_token_usage` with a proper per-stage breakdown.

### Staged delivery: nerv → medplum → eshoponweb

Implementation follows a strict gate order: Stage 1 (hello world) → Stage 2 (tokenscope) → Stage 3 (security) → Stage 4 (multistage) → Stage 5 (nerv MVP mock) → Stage 6 (nerv real) → medplum → eshoponweb. No next stage starts until previous passes on both mock and real LLM. medplum and eshoponweb built directly with opencode pattern — the old "pending SSH two-image pattern" items are superseded.

---

## SDK Migration — Two-Image SSH Architecture (2026-06-10)

### Single-image approach discarded

First implementation replaced the old OpenHands CLI container with a single `python:3.11.9-slim` image that installs `openhands-ai` + Node.js 20. This worked structurally but had a scaling problem: every project type needs its own `Dockerfile.openhands` embedding the project runtime (Node.js for nerv, .NET for eshoponweb, etc.). The agent image is never reusable across project types.

### Worker container was dead weight in single-image mode

The worker Dockerfile's CMD comment read: "Keeps the container alive for docker exec commands from the agent." With OpenHands SDK's `LocalRuntime`, the agent runs commands inside its own container — no docker exec, no Docker socket. The worker was kept in compose but served no purpose.

Once this was recognised, the correct response was not to delete the worker but to redesign: if the worker is the right execution environment (it has the project runtime, correct UID, correct tools), make the agent use it.

### Two-image architecture

Worker: project runtime (Node.js, .NET, etc.) + `openssh-server`. Runs `sshd`. Receives commands from agent over SSH as `sandboxuser`.

Agent: `python:3.11.9-slim` + `openhands-ai` + `paramiko`. Project-agnostic. All project types use the same `ai-sandbox-agent` image built from `docker/Dockerfile.agent`. SSHes into worker to execute all build/test/start commands.

This gives one agent image across all project types. Only worker images differ per project — they already did.

### Ephemeral SSH key distribution

`run_agent.sh` generates a fresh `ed25519` key pair before compose up. Public key passed to worker via `AGENT_SSH_PUBKEY` env var; worker entrypoint writes it to `sandboxuser`'s `authorized_keys` then execs `sshd`. Private key bind-mounted read-only into agent container at `/run/secrets/ssh_key`. Both files deleted in cleanup trap. No persistent keys, no hardcoded credentials.

### Worker needs internet — sandbox-internal constraint dropped

Initial plan made the sandbox network `--internal` to prevent worker (running untrusted code) from making outbound calls. But the agent SSHes into worker to run `npm install` — those commands execute on the worker, which needs npm registry access. Worker can't be on an internal-only network.

Resolution: worker joins the `llm` network alongside the agent container. Both get internet. Redis and other data services stay on sandbox-only. The `--internal` flag was dropped; security relies on Docker socket removal, resource limits, and `cap_drop: ALL` instead.

### SSHRuntime open question

`openhands_runner.py` needs a custom `SSHRuntime` class (paramiko-based) implementing OpenHands' `Runtime` interface. Key unknown before implementation: does `run_controller` accept an arbitrary runtime object passed by the caller, or does it only accept runtimes created via `create_runtime(config)`? If the former, the custom runtime pattern works directly. If the latter, need to configure via `AppConfig` remote runtime settings. Captured in PLAN.md open question 1.

### Docs updated before implementation

Architecture decision finalised in PLAN.md before any code changes to the SSH-related files. CLAUDE.md and ARCHITECTURE.md updated to reflect the two-image pattern. This caught the worker-internet issue (open question 3 in original PLAN) before it would have caused a silent `npm install` failure on first run.
