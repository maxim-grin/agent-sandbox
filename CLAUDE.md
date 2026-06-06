# AI Agent Sandbox for Nerv

## General Notes

- Do not scan the `.git` directory — it contains no useful information for this project.
- When using Bash to read logs or large files, pipe through `head`, `tail`, or `grep` to keep output small. Never `cat` large files — use `Read` with `offset`/`limit` instead.

## Adding a New Project Stack

Create three things — no supervisor changes needed.

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

- Add `"<type>"` to the `project_type` enum in `schemas/job_spec.schema.json`.
- Add `scripts/run_<type>_example.sh` following the pattern of existing example scripts: build images, create Docker resources, start supervisor, send EXEC/HEALTHCHECK/DONE commands, print result summary.

### Key invariants

- **Container name** must be `${RUN_ID}-<type>-worker-1`. The supervisor hardcodes this pattern in `orchestrate.sh` when waiting for the worker healthcheck and in `exec.sh` when routing `EXEC` commands.
- **Network and volumes are external** — created by the harness before compose runs, destroyed after. Never declare them as `driver: local` in the compose file.
- **Non-root only** — all agent commands run as `sandboxuser` (UID 1001). Ensure the runtime image supports non-root execution; some base images need extra setup (e.g. `chmod` on global tool dirs).
- **EXEC word-splitting** — `sandbox_exec` joins everything after the label with `$*` and passes it to `sh -c`. Shell operators (`&`, `&&`, pipes) work. Arguments with internal spaces must use `env VAR=val cmd` form or `sh -c '...'` quoting rather than `export VAR && cmd`.

---

## Agent Guidance: Using the Sandbox

This sandbox is **not a CI pipeline**. It provides an isolated environment, a cloned workspace, and a way to execute arbitrary commands. The agent is responsible for reading project manifests, deciding which commands to run, and interpreting the results.

### Workspace inspection

When inspecting a cloned repo, **avoid a full recursive scan**. Target only files that directly describe how the project is built, tested, and run:

| Priority | Files to read |
|----------|--------------|
| Always | `package.json` / `Cargo.toml` / `pyproject.toml` (or equivalent manifest) |
| Always | `Dockerfile`, `docker-compose.yml`, `.dockerignore` |
| Always | `README.md`, `CONTRIBUTING.md` (top-level only) |
| If present | `tsconfig.json`, `jest.config.*`, `vitest.config.*`, `Makefile`, `.env.example` |
| If present | CI config (`.github/workflows/`, `.gitlab-ci.yml`) |
| Skip | `src/**`, `lib/**`, `dist/**`, `node_modules/**`, test fixtures, generated files |

Reading every source file adds noise, bloats context, and risks pulling in application-domain details irrelevant to building and running the project.

### Driving the sandbox

Once `SANDBOX_READY` is printed, write commands to the supervisor's stdin:

- `EXEC <label> <cmd> [args...]` — run a command in the worker; output goes to `logs/<label>.log`
- `HEALTHCHECK <url>` — curl the URL and record the HTTP status
- `DONE` — signal success; supervisor writes `result.json` and tears down

The supervisor replies with `EXIT_CODE <label> <code>` after each `EXEC`. Branch on non-zero codes before continuing.

### Interpreting failures

- Exit code **137** from a worker container = OOM kill. The job needs more memory or a leaner build step.
- Non-zero `test_exit_code` in `result.json` = tests failed; read `logs/test.log`.
- `healthcheck_status` other than 200 = service did not start correctly; read `logs/run.log`.

You are helping design and implement a **Docker-based AI agent sandbox**.

This sandbox is an **execution environment for AI coding agents**, not a traditional CI pipeline. It must be generic enough to support multiple technology stacks in the future, but in this exercise it will be **validated against a single real project**:

- Project: **Nerv**
- Repo: `https://github.com/maxim-grin/nerv`
- Stack: **TypeScript / Node.js / Redis**
- “Works” definition:
  - Server builds and starts
  - Redis is available and working
  - API responds to a health check
  - Test suite passes

The design priorities are:

- **Single sandbox + pluggable stack images**
- **Separate data services per stack**
- **Clean state per run**
- **Non-interactive execution**
- **Structured output capture**
- Go deep on:
  - **Security and isolation**
  - **Resource management**
  - **Build performance**

---

## High-Level Architecture (Fixed Decisions)

These are already decided and must be respected.

### 1. Single sandbox + pluggable workers

- From the AI harness’s perspective, there is **one sandbox type** that can be configured per job.
- Internally, the sandbox consists of:
  - A **generic “supervisor” container** (stack-agnostic).
  - One or more **pluggable “worker” / stack containers** (start with Nerv’s Node+Redis stack).
- The supervisor knows **how to run a job**, not **how to build Nerv specifically**.

### 2. Separate data services per stack

- The Nerv stack includes its own **Redis** container.
- Future stacks (e.g., Postgres, SQL Server, etc.) would get their **own DB/service containers**.
- No shared databases between unrelated projects or between runs.

### 3. Clean state per run (must-have)

- Each job run must start from a **clean workspace** and **clean data state**:
  - No leftover source code.
  - No leftover Redis data.
- It must be easy to:
  - Spin up a fresh sandbox for a job.
  - Tear it down or reset deterministically and quickly.

### 4. Non-interactive execution (must-have)

- Everything must run **headlessly**:
  - No interactive prompts.
  - No wizards.
  - No manual license dialogs.
- Any tools that are normally interactive must be configured with flags/env vars to run non-interactively.

### 5. Structured output capture (must-have)

- Build and test results must be exposed in a **machine-readable way**, not just terminal logs.
- At minimum:
  - Clear **exit codes** for the overall job.
  - A **JSON result file** with status and summary.
  - Logs written to known paths.

### 6. Depth areas

You should go **deeper than usual** on:

- **Security and isolation** (sandboxing untrusted code).
- **Resource management** (CPU, memory, disk).
- **Build performance** (startup time, caching, multi-stage builds).

---

## Responsibilities: Sandbox vs AI Agent

This separation is critical.

### Sandbox responsibilities

The **sandbox** is responsible for:

- Providing an **isolated, reproducible environment**:
  - Supervisor + stack-specific worker containers.
  - A dedicated Docker network and volumes per run.
- Providing tools and services for the Nerv stack:
  - Node.js / TypeScript toolchain.
  - Redis.
- Managing **lifecycle and clean state** for each run:
  - Fresh workspace.
  - Fresh Redis data.
- Enforcing:
  - **Non-interactive execution.**
  - **Security and isolation controls.**
  - **Resource limits** (CPU, memory, disk).
- Capturing:
  - Logs (build/test/run).
  - A structured `result.json`.

### AI agent responsibilities

The **AI coding agent / harness** is responsible for:

- Inspecting the repository contents (inside the sandbox workspace), including:
  - `package.json`
  - `Dockerfile`
  - `docker-compose.yml` (if present)
  - Any other relevant docs
- **Figuring out how to:**
  - Install dependencies.
  - Build the project.
  - Run tests.
  - Start the service and probe a healthcheck.
- Deciding which concrete shell commands to run, in what order.
- Executing those commands inside the sandbox (via the supervisor’s execution entrypoint).
- Interpreting the logs/result JSON and deciding what to do next.

> Important:  
> **The sandbox must not hard-code any project-specific build/test/run commands (e.g., `npm run build`, `npm test`, `npm start`).**  
> The sandbox exposes an environment and a way to run arbitrary commands; the AI agent chooses the commands based on `package.json`, Dockerfile, and existing project conventions.

---

## Job Spec and Lifecycle

Define a **minimal job spec** that the supervisor can accept (passed as a JSON file or environment variables).

Example job spec:

```json
{
  "project_type": "node_redis",
  "repo_url": "https://github.com/maxim-grin/nerv",
  "commit": "main"
}
```

Notes:

- There are **no `build_command` / `test_command` / `run_command` fields**.
- The job spec only tells the sandbox:
  - What kind of stack to provision (`project_type`).
  - Which repo and commit to clone.
- After the repo is cloned into the workspace, the AI agent is expected to:
  - Read `package.json`, Dockerfile, and any relevant files.
  - Decide which commands to run for build/test/run.
  - Execute them using the sandbox’s execution capability.

### Supervisor responsibilities

The **supervisor container** must:

1. Accept a job spec.
2. Ensure a **clean workspace** for the run (e.g., `/sandbox/workspace`).
3. Clone the repo at the specified commit into the workspace.
4. Select the appropriate worker stack based on `project_type`.
5. Orchestrate the worker/Redis containers (e.g., via `docker-compose` or `docker run`).
6. Provide a way for an AI agent (or a simple driver script in this exercise) to:
   - Run arbitrary commands inside the worker container.
7. Capture logs and produce a structured result:
   - Logs and `result.json` in a known location.
8. Exit with a clear success/failure status code.

You may include a **simple driver script** (e.g., `run_nerv_example.sh`) that imitates what an agent would do by:

- Reading `package.json` to find `build`, `test`, `start` scripts.
- Running those commands in sequence.

This script must be clearly labeled in the README as an **example harness**, not core sandbox behavior.

---

## Workers: Nerv Stack

Implement a **Nerv stack worker** that provides:

- Node.js / TypeScript build and test tooling.
- A Redis container reachable at a known host/port.
- Ability to run arbitrary commands supplied by the agent/supervisor.

Acceptable implementation patterns:

- `docker-compose.nerv.yml` with:
  - `nerv-worker` service.
  - `redis` service.
- Or:
  - A dedicated worker image started with `docker run`, plus a separate Redis container on the same network.

Capabilities:

- Run typical Node/TypeScript commands like:
  - `npm install`
  - `npm run build`
  - `npm test`
  - `npm start`
- Respond to a health check (e.g., HTTP GET to a URL the agent discovers from Dockerfile or code/docs).
- Run non-interactively.

---

## Results and Logs

Define a standard results layout, for example:

- Base: `/sandbox/results`
  - `/sandbox/results/logs/build.log`
  - `/sandbox/results/logs/test.log`
  - `/sandbox/results/logs/run.log` (if applicable)
  - `/sandbox/results/result.json`

`result.json` should at least contain:

```json
{
  "status": "success",
  "build_exit_code": 0,
  "test_exit_code": 0,
  "healthcheck_status": 200,
  "duration_seconds": 123
}
```

Requirements:

- Every job run must produce a `result.json` and logs.
- The supervisor’s main process exit code must reflect overall job success/failure.
- An external AI harness should be able to mount/read `/sandbox/results`.

---

## Clean State

Each job must start from a known-clean state:

- No leftover workspace contents.
- No leftover Redis data.

Acceptable approaches:

- Use throwaway containers and volumes per run and then destroy them.
- Or implement explicit reset logic that reliably clears workspace and data.

Document in `README.md`:

- How to start a new job run.
- How you guarantee there is no state leakage between runs.

---

## Security and Isolation

Treat the code running in the worker as **untrusted**.

Minimum expectations:

- File system:
  - Limit container mounts to what is needed (workspace, results).
  - No direct access to host filesystem beyond these.
- Network:
  - Use a dedicated Docker network for the sandbox.
  - Restrict external outbound access as reasonable for the exercise.
- Container hardening:
  - Run as non-root where feasible.
  - Drop unnecessary Linux capabilities.
  - Consider `no-new-privileges`.

If the supervisor needs to orchestrate containers:

- Minimize exposure of the host Docker socket.
- Document any tradeoffs (e.g., using Docker socket vs. sidecar approaches).
- Call out remaining risks and how you would harden this in production.

---

## Resource Management

Implement and document resource controls:

- Per-container CPU/memory limits for:
  - Supervisor.
  - Nerv worker.
  - Redis.
- Disk considerations:
  - Ephemeral volumes where possible.
  - Avoid unbounded logs.

Document:

- What happens when builds/tests hit resource limits.
- How an AI harness can interpret resource-related failures (e.g., OOM, timeouts).

---

## Build Performance

Design for **reasonable startup and iteration speed**:

- Use multi-stage builds to keep images lean.
- Pre-install common tools (e.g., Node runtime) to leverage Docker layer caching.
- Avoid unnecessary work on each run.

Document:

- Approximate observed time for a Nerv job run.
- How you would improve further at scale (e.g., warm worker pools, shared caches, microVM-based sandboxes).

---

## Deliverables

Implement:

1. **Docker configuration**
   - `Dockerfile` for supervisor.
   - Dockerfile(s) and/or `docker-compose` for the Nerv worker + Redis.
   - Helper scripts, for example:
     - `run_job.sh` – entrypoint to run a job spec.
     - `run_nerv_example.sh` – an example script that simulates an AI harness
       by reading `package.json` and deciding which npm scripts to run
       (must be labeled as an example).

2. **Documentation (`README.md`)**
   - Explain architecture: supervisor + pluggable workers, Nerv as the example.
   - Describe the job spec and lifecycle.
   - Explain how clean state, security, resource limits, and performance are handled.
   - Explicitly state that:
     - The sandbox is **agent-oriented**, not a fixed CI pipeline.
     - Any included example scripts are **harness simulations**, not the required way to use the sandbox.

3. **Proof it works**
   - Clear instructions to:
     - Build images.
     - Start the sandbox.
     - Run a job against the Nerv repo.
   - Evidence that:
     - Nerv builds.
     - Tests pass.
     - Redis works.
     - A health check responds.
   - Optionally, add example logs/result.json under `docs/` or similar.

---

## How to Start

1. Propose a concrete directory structure for this repo.
2. Sketch the supervisor and Nerv worker Dockerfiles and/or `docker-compose` files.
3. Implement:
   - Supervisor logic for job spec → workspace → worker orchestration → result/log capture.
   - Nerv worker stack with Redis.
4. Add a simple example script that:
   - Reads `package.json` from the Nerv repo.
   - Infers appropriate `npm` scripts for build/test/run.
   - Executes them inside the sandbox to produce a full example run.
5. Write or update `README.md` to clearly explain the design and tradeoffs.
