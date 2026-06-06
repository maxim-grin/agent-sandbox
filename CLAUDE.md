# AI Agent Sandbox for Nerv

## General Notes

- Don't scan `.git` — no useful info there.
- Pipe Bash log reads through `head`, `tail`, or `grep`. Never `cat` large files — use `Read` with `offset`/`limit`.

## Pipeline Run Procedure

End-to-end pipeline run:
1. **Single run** only.
2. Concise report: passed, failed, root causes, fix options.
3. **Stop** — don't re-run with fix applied. Ask user first.

## Adding a New Project Stack

Three things to create — no supervisor changes needed.

### 1. `projects/<type>/worker/Dockerfile`

```dockerfile
FROM <runtime-image>   # must be multi-arch if Apple Silicon support is needed

RUN <install git curl and any system deps>

RUN groupadd -g 1001 sandboxgroup && useradd -u 1001 -g sandboxgroup -m sandboxuser
RUN mkdir -p /workspace /sandbox/results/logs \
    && chown -R sandboxuser:sandboxgroup /workspace /sandbox

WORKDIR /workspace
USER sandboxuser

HEALTHCHECK --interval=5s --timeout=5s --retries=3 CMD <runtime version check>
CMD ["sleep", "infinity"]
```

### 2. `projects/<type>/docker-compose.yml`

```yaml
services:
  worker:
    image: "${WORKER_IMAGE}"
    container_name: "${RUN_ID}-<type>-worker-1"  # exact pattern — supervisor derives worker name from this
    networks: [sandbox]
    volumes:
      - workspace:/workspace
      - results:/sandbox/results
    working_dir: /workspace
    environment:
      CI: "true"
      # stack-specific env vars
    mem_limit: <Xg>
    cpus: <N>
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    user: sandboxuser
    command: ["sleep", "infinity"]
    healthcheck:
      test: ["CMD", "<version check>"]
      interval: 5s
      timeout: 5s
      retries: 3
      start_period: 10s

  # optional data service containers (postgres, redis, …)
  # use compose-managed (not external) volumes so `docker compose down -v` cleans them up

networks:
  sandbox:
    external: true
    name: "${SANDBOX_NETWORK}"

volumes:
  workspace:
    external: true
    name: "${WORKSPACE_VOLUME}"
  results:
    external: true
    name: "${RESULTS_VOLUME}"
```

### 3. Schema + example script

- Add `"<type>"` to `project_type` enum in `schemas/job_spec.schema.json`.
- Add `scripts/run_<type>_example.sh` matching existing example scripts: build images, create Docker resources, start supervisor, send EXEC/HEALTHCHECK/DONE commands, print result summary.

### Key invariants

- **Container name** must be `${RUN_ID}-<type>-worker-1`. Supervisor hardcodes this in `orchestrate.sh` (worker healthcheck) and `exec.sh` (EXEC routing).
- **Network and volumes are external** — harness creates before compose, destroys after. Never `driver: local` in compose file.
- **Non-root only** — agent commands run as `sandboxuser` (UID 1001). Verify runtime image supports non-root; some base images need extra setup (e.g. `chmod` on global tool dirs).
- **EXEC word-splitting** — `sandbox_exec` joins everything after label with `$*`, passes to `sh -c`. Shell operators (`&`, `&&`, pipes) work. Args with internal spaces need `env VAR=val cmd` or `sh -c '...'` quoting, not `export VAR && cmd`.

---

## Agent Guidance: Using the Sandbox

Sandbox is **not a CI pipeline**. Isolated env + cloned workspace + arbitrary command execution. Agent reads manifests, decides commands, interprets results.

### Workspace inspection

Avoid full recursive scan. Target only files describing build/test/run:

| Priority | Files to read |
|----------|--------------|
| Always | `package.json` / `Cargo.toml` / `pyproject.toml` (or equivalent manifest) |
| Always | `Dockerfile`, `docker-compose.yml`, `.dockerignore` |
| Always | `README.md`, `CONTRIBUTING.md` (top-level only) |
| If present | `tsconfig.json`, `jest.config.*`, `vitest.config.*`, `Makefile`, `.env.example` |
| If present | CI config (`.github/workflows/`, `.gitlab-ci.yml`) |
| Skip | `src/**`, `lib/**`, `dist/**`, `node_modules/**`, test fixtures, generated files |

Reading every source file adds noise, bloats context, pulls in irrelevant details.

### Driving the sandbox

Once `SANDBOX_READY` prints, write commands to supervisor stdin:

- `EXEC <label> <cmd> [args...]` — run command in worker; output → `logs/<label>.log`
- `HEALTHCHECK <url>` — curl URL, record HTTP status
- `DONE` — signal success; supervisor writes `result.json` and tears down

Supervisor replies `EXIT_CODE <label> <code>` after each `EXEC`. Branch on non-zero before continuing.

### Interpreting failures

- Exit code **137** = OOM kill. Needs more memory or leaner build.
- Non-zero `test_exit_code` in `result.json` = tests failed; read `logs/test.log`.
- `healthcheck_status` not 200 = service didn't start; read `logs/run.log`.

Design and implement a **Docker-based AI agent sandbox**.

Sandbox is **execution env for AI coding agents**, not CI. Generic enough for multiple stacks, validated against one real project:

- Project: **Nerv**
- Repo: `https://github.com/maxim-grin/nerv`
- Stack: **TypeScript / Node.js / Redis**
- "Works" means:
  - Server builds and starts
  - Redis available and working
  - API responds to health check
  - Test suite passes

Design priorities:

- **Single sandbox + pluggable stack images**
- **Separate data services per stack**
- **Clean state per run**
- **Non-interactive execution**
- **Structured output capture**
- Go deep on: **Security/isolation**, **resource management**, **build performance**

---

## High-Level Architecture (Fixed Decisions)

Already decided — must be respected.

### 1. Single sandbox + pluggable workers

- AI harness sees **one sandbox type**, configurable per job.
- Internally: **generic supervisor** (stack-agnostic) + **pluggable worker/stack containers**.
- Supervisor knows **how to run a job**, not **how to build Nerv**.

### 2. Separate data services per stack

- Nerv stack has own **Redis** container.
- Future stacks get **own DB/service containers**.
- No shared databases between projects or runs.

### 3. Clean state per run (must-have)

Each run starts from **clean workspace** and **clean data**:
- No leftover source code.
- No leftover Redis data.
- Easy to spin up fresh, tear down deterministically.

### 4. Non-interactive execution (must-have)

Everything runs **headlessly** — no prompts, wizards, or license dialogs. Interactive tools must use flags/env vars.

### 5. Structured output capture (must-have)

Machine-readable results:
- Clear **exit codes**.
- **JSON result file** with status/summary.
- Logs at known paths.

### 6. Depth areas

Go deeper than usual on: **security/isolation**, **resource management**, **build performance**.

---

## Responsibilities: Sandbox vs AI Agent

Critical separation.

### Sandbox responsibilities

- **Isolated, reproducible env**: supervisor + stack worker containers, dedicated Docker network + volumes per run.
- Tools/services for Nerv: Node.js/TypeScript toolchain, Redis.
- **Lifecycle + clean state**: fresh workspace, fresh Redis per run.
- Enforce: non-interactive, security/isolation, resource limits.
- Capture: logs, structured `result.json`.

### AI agent responsibilities

- Inspect repo contents in sandbox workspace (`package.json`, `Dockerfile`, `docker-compose.yml`, docs).
- **Figure out** how to install deps, build, run tests, start service, probe healthcheck.
- Decide concrete shell commands and order.
- Execute via supervisor's execution entrypoint.
- Interpret logs/result JSON and decide next steps.

> Important:  
> **Sandbox must not hard-code project-specific build/test/run commands (e.g., `npm run build`, `npm test`, `npm start`).**  
> Sandbox exposes env + arbitrary command execution; agent chooses commands based on `package.json`, Dockerfile, project conventions.

---

## Job Spec and Lifecycle

Minimal job spec accepted by supervisor (JSON file or env vars).

Example:

```json
{
  "project_type": "node_redis",
  "repo_url": "https://github.com/maxim-grin/nerv",
  "commit": "main"
}
```

No `build_command`/`test_command`/`run_command` fields. Spec only tells sandbox: stack type, repo, commit. Agent then reads files and decides commands.

### Supervisor responsibilities

1. Accept job spec.
2. Ensure **clean workspace** (e.g., `/sandbox/workspace`).
3. Clone repo at specified commit.
4. Select worker stack from `project_type`.
5. Orchestrate worker/Redis containers.
6. Provide arbitrary command execution in worker.
7. Capture logs, produce structured result.
8. Exit with clear success/failure code.

Include **simple driver script** (e.g., `run_nerv_example.sh`) imitating agent behavior — reads `package.json`, runs build/test/start in sequence. Must be labeled **example harness**, not core sandbox behavior.

---

## Workers: Nerv Stack

Nerv stack worker provides: Node.js/TypeScript toolchain, Redis reachable at known host/port, arbitrary command execution.

Acceptable patterns:
- `docker-compose.nerv.yml` with `nerv-worker` + `redis` services.
- Or: dedicated worker image via `docker run` + separate Redis on same network.

Capabilities:
- `npm install`, `npm run build`, `npm test`, `npm start`
- Respond to health check.
- Non-interactive.

---

## Results and Logs

Standard layout:

- `/sandbox/results/logs/build.log`
- `/sandbox/results/logs/test.log`
- `/sandbox/results/logs/run.log`
- `/sandbox/results/result.json`

`result.json` minimum:

```json
{
  "status": "success",
  "build_exit_code": 0,
  "test_exit_code": 0,
  "healthcheck_status": 200,
  "duration_seconds": 123
}
```

Every run must produce `result.json` + logs. Supervisor exit code reflects overall success. External harness mounts/reads `/sandbox/results`.

---

## Clean State

Each run from known-clean state — no leftover workspace, no leftover Redis data.

Options: throwaway containers/volumes per run, or explicit reset logic. Document in `README.md`: how to start new run, how state leakage is prevented.

---

## Security and Isolation

Treat worker code as **untrusted**.

Minimums:
- **Filesystem**: limit mounts to workspace + results. No host filesystem beyond that.
- **Network**: dedicated Docker network. Restrict external outbound where reasonable.
- **Container hardening**: non-root, drop unnecessary Linux capabilities, `no-new-privileges`.

If supervisor orchestrates containers:
- Minimize host Docker socket exposure.
- Document tradeoffs (Docker socket vs. sidecar).
- Call out remaining risks + production hardening path.

---

## Resource Management

Implement and document:
- Per-container CPU/memory limits for supervisor, Nerv worker, Redis.
- Ephemeral volumes where possible. Avoid unbounded logs.

Document: what happens when builds/tests hit limits, how harness interprets resource failures (OOM, timeouts).

---

## Build Performance

Design for **fast startup and iteration**:
- Multi-stage builds — lean images.
- Pre-install common tools to leverage layer caching.
- Avoid unnecessary per-run work.

Document: observed Nerv job run time, how to improve at scale (warm worker pools, shared caches, microVM sandboxes).

---

## Deliverables

1. **Docker configuration**
   - `Dockerfile` for supervisor.
   - Dockerfile(s) and/or `docker-compose` for Nerv worker + Redis.
   - Helper scripts: `run_job.sh` (job spec entrypoint), `run_nerv_example.sh` (example harness simulation — labeled as such).

2. **Documentation (`README.md`)**
   - Architecture: supervisor + pluggable workers, Nerv as example.
   - Job spec and lifecycle.
   - Clean state, security, resource limits, performance.
   - Explicit: sandbox is **agent-oriented**, example scripts are **harness simulations**.

3. **Proof it works**
   - Build/start/run instructions.
   - Evidence: Nerv builds, tests pass, Redis works, health check responds.
   - Optional: example logs/result.json under `docs/`.

---

## How to Start

1. Propose concrete directory structure.
2. Sketch supervisor and Nerv worker Dockerfiles and/or `docker-compose`.
3. Implement: supervisor logic (spec → workspace → worker orchestration → result capture) + Nerv worker stack with Redis.
4. Add example script: reads `package.json`, infers npm scripts, executes for full example run.
5. Write/update `README.md` — design and tradeoffs.