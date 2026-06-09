# AI Agent Sandbox

Docker-based execution environment for AI coding agents. Sandbox provides isolated, reproducible workspace; AI agent decides what to build, test, and run.

---

## Architecture

```
Host
├── scripts/run_agent.sh     # agent mode: clone, start OpenHands, wait for autonomous completion
├── examples/                # harness simulations (deterministic demos)
│
├── Supervisor container     # harness mode only — stack-agnostic orchestrator
│   ├── clones repo into workspace volume
│   ├── starts worker stack via docker compose
│   ├── signals SANDBOX_READY on stdout
│   └── accepts EXEC / HEALTHCHECK / DONE on stdin
│       │
│       └── Worker stack (projects/<project_type>/)
│           ├── worker    runtime container, workspace volume at /workspace
│           └── services  data services (Redis, PostgreSQL, …)
│
└── OpenHands container      # agent mode only — autonomous LLM agent
    ├── reads cloned workspace at /workspace
    ├── figures out runtime, deps, build, test, start, healthcheck
    └── writes result.json to /sandbox/results/
```

### Two runner modes

| Mode | Runner | Who decides commands | Use when |
|------|--------|----------------------|----------|
| **Harness** | example scripts | Script (hardcoded workflow) | Deterministic demo, debugging |
| **Agent** | `run_agent.sh` | OpenHands LLM (autonomous) | Real AI evaluation of unknown repos |

Both modes: same Docker network/volume pattern, same `run_results/{project}/{runid}/` output.

### Projects (pluggable worker stacks)

```
projects/
├── nerv/         Node 20 + Redis
├── medplum/      Node 22 + PostgreSQL + Redis
└── eshoponweb/   .NET SDK 10, in-memory EF Core
```

Each project contains:

- `docker-compose.yml` — worker + data services + OpenHands service (profile `agent`)
- `worker/Dockerfile` — runtime image for harness mode

---

## Quickstart

### Prerequisites

- Docker Engine 24+ with Compose plugin
- `jq`

### Harness mode (deterministic demo)

```bash
# builds images, drives supervisor with hardcoded npm workflow
./examples/run_nerv_example.sh
```

### Agent mode (OpenHands autonomous)

```bash
# 1. configure LLM credentials
cp .example.env .env
# edit .env: set GROQ_API_KEY (and optionally LLM_MODEL, LLM_BASE_URL)

# 2. run
./scripts/run_agent.sh job_specs/nerv.json
```

Results appear in `run_results/<project>/<run-id>/` on the host.

---

## Job Spec

Same schema for both modes:

```json
{
  "project_type": "nerv",
  "repo_url": "https://github.com/maxim-grin/nerv",
  "commit": "main"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `project_type` | yes | Maps to directory under `projects/` |
| `repo_url` | yes | HTTPS URL of git repository to clone |
| `commit` | no | Branch, tag, or full SHA. Default: `main` |

No `build_command`, `test_command`, or `run_command` fields. Sandbox provides env; agent decides commands.

---

## OpenHands Agent Runner

### Config

```bash
# .example.env — copy to .env and fill in
LLM_MODEL=groq/llama-3.1-8b-instant
GROQ_API_KEY=
LLM_BASE_URL=https://api.groq.com/openai/v1
```

`run_agent.sh` loads `.env` automatically. `.env` is gitignored; `.example.env` is committed.

### Prompt

Task prompt: `projects/<project_type>/prompt.txt` — one file per project, containing stack-specific context and known quirks. Runner reads `projects/${PROJECT_TYPE}/prompt.txt` → exports `TASK` → compose substitutes into OpenHands command. Errors if no prompt file exists for the project type.

### How it works

1. Creates per-run Docker network + volumes
2. Clones repo into workspace volume (shallow clone)
3. Starts project's compose with `--profile agent` → launches data services + OpenHands
4. OpenHands reads workspace, infers stack, runs build/test/start/healthcheck autonomously
5. OpenHands writes `result.json` to `/sandbox/results/`
6. Runner waits for OpenHands container to exit, copies results to host, tears down

### OpenHands in compose

Each project's `docker-compose.yml` includes OpenHands as a `profiles: [agent]` service. Default `docker compose up -d` (supervisor/harness path) does NOT start it. Only `run_agent.sh` activates it via `--profile agent`.

### Result schema (agent mode)

```json
{
  "status": "success|failure",
  "build":        { "status": "...", "command": "...", "exit_code": 0,   "logs": "..." },
  "start_server": { "status": "...", "command": "...",                    "logs": "..." },
  "tests":        { "status": "...", "command": "...", "passed": 0, "failed": 0, "logs": "..." },
  "health_check": { "status": "...", "url": "...", "response_code": 200, "logs": "..." },
  "errors":       [],
  "duration_seconds": 0
}
```

---

## Harness Mode: Agent Command Protocol

Once sandbox ready, supervisor prints:

```
SANDBOX_READY run_id=<id> worker=<id>-<project_type>-worker-1
```

Harness writes commands to supervisor stdin:

| Command | Description |
|---------|-------------|
| `EXEC <label> <cmd>` | Runs in worker as `sandboxuser`. Output → `logs/<label>.log`. Labels `build`/`test` auto-populate `result.json`. |
| `HEALTHCHECK <url>` | Curls `<url>`, records HTTP status. |
| `DONE` | Signals success; supervisor writes `result.json` and tears down. |

Supervisor prints `EXIT_CODE <label> <code>` after each `EXEC`.

---

## Adding a New Stack

Tell Claude:

> Add `<name>` as new project type. Stack: `<runtime + data services>`. Repo: `<url>`. "Works" means: builds, tests pass, `<health endpoint>` returns 200. `<constraints>`.

Required files and naming conventions documented in `CLAUDE.md`.

---

## Clean State

Each run gets its own resources, all namespaced by `run-id`:

| Resource | Name | Lifecycle |
|----------|------|-----------|
| Docker network | `<run-id>` | created before run, removed on exit |
| Workspace volume | `<run-id>-workspace` | created empty, cloned into at start |
| Results volume | `<run-id>-results` | persists for post-run inspection |

Data services use compose-managed volumes, removed by `docker compose down -v`. No shared state between runs.

---

## Results Layout

```
run_results/
└── <project_name>/
    └── <run-id>/
        ├── result.json
        ├── supervisor.log      # harness mode only
        ├── agent_output.log    # agent mode only (OpenHands JSON stream)
        └── logs/
            ├── build.log
            ├── test.log
            └── ...
```

`project_name` = last path segment of `repo_url` (`.git` stripped).

Harness mode `result.json` schema:

```json
{
  "run_id": "sandbox-1717612345",
  "status": "success",
  "build_exit_code": 0,
  "test_exit_code": 0,
  "healthcheck_status": 200,
  "duration_seconds": 63,
  "steps": [...]
}
```

---

## Security and Isolation

### Worker container (harness mode)

- Non-root: `sandboxuser` (UID 1001)
- `--security-opt no-new-privileges`
- All Linux capabilities dropped
- Mounts limited to workspace + results volumes
- Isolated on per-run Docker bridge network

### OpenHands container (agent mode)

- Uses local runtime (no Docker socket — commands run inside OpenHands container)
- Mounts: workspace + results volumes only
- On same per-run sandbox network as data services

### Supervisor container

- Docker socket mounted read-only (`/var/run/docker.sock:ro`) — required to manage worker stack
- Only `projects/<project_type>/` mounted read-only; cannot access other stacks
- Production hardening: replace socket with rootless Docker or scoped container runtime API

### Network

- Dedicated bridge network per run; runs are isolated from each other
- Worker has unrestricted outbound internet (required for `npm install`, `dotnet restore`, etc.)
- For higher security: route through caching proxy (Verdaccio, NuGet feed) + egress firewall

---

## Resource Limits

| Container | Memory | CPU |
|-----------|--------|-----|
| Supervisor | 256 MB | 0.5 |
| Worker | see project README | see project README |
| OpenHands | no limit set (inherits host) | no limit set |

**OOM**: Docker kills container, exit code 137. Supervisor writes `"status": "failure"`.  
**CPU throttle**: worker slows, harness timeouts may fire.

---

## Timeouts (harness mode)

| Variable | Default | Controls |
|----------|---------|----------|
| `TIMEOUT_TOTAL` | `1800` | Whole-job wall-clock limit. Exceeded → supervisor sends SIGUSR1, writes `"status": "timeout"`, tears down. |
| `TIMEOUT_EXEC` | `600` | Per-EXEC-step limit. Timed-out step exits `124`; command loop continues. |
| `TIMEOUT_STACK_HEALTHY` | `120` | Max wait for worker Docker healthcheck. |

Configure in `.env`:

```bash
TIMEOUT_TOTAL=3600
TIMEOUT_EXEC=900
TIMEOUT_STACK_HEALTHY=60
```

`run_agent.sh` sources `.env` automatically.

---

## Build Performance

- Worker images built once, reused across runs. Source never baked into image — arrives via workspace volume at runtime.
- Shallow clone (`--depth=1`) for fast workspace setup.
- Layer caching: subsequent runs with same `project_type` reuse cached image.

Scale improvements: persistent package cache volume (`~/.npm`, `~/.nuget/packages`), warm worker pools, registry mirror (Verdaccio), microVM isolation (Firecracker/Kata).

---

## Agent-Oriented Design

Sandbox is **not a CI pipeline**. Provides isolated env + runtime + cloned workspace + arbitrary command execution. Agent (harness script or OpenHands LLM) decides what to install, build, test, and run by reading project manifests.

Scripts in `examples/` are **harness simulations** — deterministic demonstrations of what an agent would do. They are not mounted into the sandbox.

Scripts in `examples/` show what an agent would do for a known stack. OpenHands reads repo manifests directly from `/workspace` to figure out the same autonomously.
