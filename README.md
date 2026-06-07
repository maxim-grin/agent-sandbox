# AI Agent Sandbox

A Docker-based execution environment for AI coding agents. The sandbox provides an isolated, reproducible workspace; the AI agent decides what to build, test, and run.

---

## Architecture

```
Host
├── scripts/run_job.sh      # builds images, creates per-run Docker resources, starts supervisor
├── examples/               # harness simulations (not used by the sandbox itself)
│
└── Supervisor container    # stack-agnostic orchestrator
    ├── clones the repo into the workspace volume
    ├── copies projects/<project_type>/CLAUDE.md → /workspace/AGENT_GUIDE.md
    ├── starts the project's worker stack via docker compose
    ├── signals SANDBOX_READY on stdout
    └── accepts agent commands on stdin (EXEC / HEALTHCHECK / DONE)
        │
        └── Worker stack (projects/<project_type>/)
            ├── worker    runtime container, workspace volume mounted at /workspace
            └── services  data services required by the stack (Redis, PostgreSQL, …)
```

### Supervisor

The supervisor (`supervisor/`) is stack-agnostic. It knows how to:

- Accept a job spec (repo URL, project type, commit)
- Clone the repo into a clean workspace
- Select and start the right worker stack based on `project_type`
- Relay agent commands into the worker via `docker exec`
- Capture logs and write a structured `result.json`

It does **not** know anything about npm, TypeScript, or any specific project.

### Projects (pluggable worker stacks)

Each subdirectory of `projects/` is a self-contained stack with a `docker-compose.yml` and a `worker/Dockerfile`. Adding a new stack requires no changes to the supervisor.

```
projects/
├── nerv/         Node 20 + Redis — see projects/nerv/README.md
├── medplum/      Node 22 + PostgreSQL + Redis — see projects/medplum/README.md
└── eshoponweb/   .NET SDK 10, in-memory EF Core (no SQL Server) — see projects/eshoponweb/README.md
```

Each project directory contains:

- `docker-compose.yml` — worker + data service containers
- `worker/Dockerfile` — runtime image for the stack
- `CLAUDE.md` — agent guide: standard commands, health endpoint, key files, failure signals. The supervisor copies this into the workspace as `AGENT_GUIDE.md` before signalling `SANDBOX_READY`.

---

## Adding a New Stack

Tell Claude:

> Add `<name>` as a new project type. Stack: `<runtime + any data services>`. Repo: `<url>`. "Works" means: builds, tests pass, and `<health endpoint>` returns 200. `<any constraints, e.g. no ARM64 image for X — use in-memory alternative>`.

The required files and naming conventions are documented in `CLAUDE.md`.

---

## Job Spec

Jobs are described as a JSON file passed to `run_job.sh`:

```json
{
  "project_type": "nerv",
  "repo_url": "https://github.com/maxim-grin/nerv",
  "commit": "main"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `project_type` | yes | Maps to a directory under `projects/` |
| `repo_url` | yes | HTTPS URL of the git repository to clone |
| `commit` | no | Branch, tag, or full SHA. Defaults to `main` |

There are no `build_command`, `test_command`, or `run_command` fields. The sandbox provides the environment; the AI agent decides the commands.

---

## Quickstart

### Prerequisites

- Docker Engine 24+ with the Compose plugin
- `jq`

```bash
# Create a job spec for one of the supported project types, then:
./scripts/run_job.sh /path/to/job.json
```

See each project's README for stack-specific job specs and quickstart instructions:

- [Nerv stack](projects/nerv/README.md)
- [Medplum stack](projects/medplum/README.md)
- [eShopOnWeb stack](projects/eshoponweb/README.md)

### Inspect results

```bash
# Replace <run-id> with the value printed by run_job.sh
docker run --rm -v <run-id>-results:/r alpine sh -c 'cat /r/result.json'
docker run --rm -v <run-id>-results:/r alpine sh -c 'ls /r/logs/'
```

---

## Agent Command Protocol

Once the sandbox is ready, the supervisor prints:

```
SANDBOX_READY run_id=<id> worker=<id>-<project_type>-worker-1
```

The AI harness drives the agent by writing commands to the supervisor's stdin:

| Command | Description |
|---------|-------------|
| `EXEC <label> <cmd> [args...]` | Runs `<cmd>` inside the worker as `sandboxuser`. Output is streamed and saved to `logs/<label>.log`. Labels `build` and `test` automatically populate `result.json`. |
| `HEALTHCHECK <url>` | Curls `<url>` and records the HTTP status code. |
| `DONE` | Signals successful completion; supervisor writes `result.json` and tears down. |

The supervisor prints `EXIT_CODE <label> <code>` after each `EXEC` so the harness can branch on failures.

---

## Clean State

Each run gets its own:

| Resource | Name | Lifecycle |
|----------|------|-----------|
| Docker network | `<run-id>` | created before supervisor starts, removed on exit |
| Workspace volume | `<run-id>-workspace` | created empty, supervisor clones into it |
| Results volume | `<run-id>-results` | created empty, survives for post-run inspection |

The workspace volume is created empty by `run_job.sh` before the supervisor starts. The supervisor clears it (`find /sandbox/workspace -mindepth 1 -delete`) before cloning as an extra guard against volume reuse.

Data services (Redis, PostgreSQL) use compose-managed volumes that are removed by `docker compose down -v` automatically. **There is no shared state between runs.** All resources are namespaced by `run-id`.

---

## Security and Isolation

### Worker container

- Runs as non-root (`sandboxuser`, UID created in the Dockerfile)
- `--security-opt no-new-privileges` prevents privilege escalation
- All Linux capabilities dropped (`cap_drop: ALL`); only `SETUID`/`SETGID` re-added for npm child process spawning
- No access to the host filesystem beyond the two named volumes (`workspace`, `results`)
- Isolated on a per-run Docker bridge network

### Data service containers

- All capabilities dropped
- No persistence beyond the current run
- Bound to the sandbox network only; not exposed to the host

### Supervisor container

- Runs with the Docker socket mounted read-only (`/var/run/docker.sock:ro`)
- The Docker socket is the primary trust boundary. In production, replace with a rootless Docker daemon, Docker-in-Docker sidecar, or a scoped container runtime API (e.g. containerd).
- Only the single project directory (`projects/<project_type>/`) is mounted read-only as `/sandbox/project` — the supervisor cannot access other project stacks

### Network

- Each run uses a dedicated Docker bridge network; containers in one run cannot reach another run's containers
- Outbound internet access from the worker is unrestricted by default (required for package restore — `npm install`, `dotnet restore`, etc.). For higher-security deployments, route through a caching proxy (e.g. Verdaccio, a NuGet feed) or add an egress firewall rule.

---

## Resource Limits

| Container | Memory | CPU |
|-----------|--------|-----|
| Supervisor | 256 MB | 0.5 |
| Worker (per stack) | see project README | see project README |

**What happens when limits are hit:**

- **Worker OOM** — Docker kills the container (exit 137). The supervisor writes `result.json` with `"status": "failure"`. Treat exit 137 as an OOM signal.
- **CPU throttle** — Worker is slowed but not killed. Harness timeouts may fire.

Stack-specific limits are documented in each project's README.

---

## Timeouts

Three timeout thresholds prevent jobs from running indefinitely.

| Variable | Default | What it controls |
|----------|---------|-----------------|
| `TIMEOUT_TOTAL` | `1800` | Whole-job wall-clock limit (seconds). When exceeded, the supervisor sends itself SIGUSR1, calls `finish("timeout")`, and tears down the stack. |
| `TIMEOUT_EXEC` | `600` | Per-`EXEC`-step limit (seconds). Wraps `docker exec` with `timeout(1)`. A timed-out step exits with code `124`; the command loop continues so the agent can decide what to do. |
| `TIMEOUT_STACK_HEALTHY` | `120` | How long to wait for the worker container to pass its Docker healthcheck before giving up. |

All three appear in `result.json` implicitly: a timed-out job has `"status": "timeout"` and step entries with `"exit_code": 124`.

### Configuring timeouts

Set the variables in a `.env` file in the repo root before running `run_job.sh`:

```bash
# .env
TIMEOUT_TOTAL=3600       # allow up to 1 hour for slow builds
TIMEOUT_EXEC=900         # allow 15 minutes per step
TIMEOUT_STACK_HEALTHY=60 # fail fast if the worker doesn't start
```

`run_job.sh` sources `.env` automatically if the file exists. Variables can also be exported in the calling shell — shell env takes precedence over `.env`.

---

## Build Performance

### Layer caching

Worker images are built once and reused across runs. Project source is never baked into the image — it arrives at runtime via the workspace volume. Some stacks use multi-stage builds to separate toolchain installation from the runtime image (e.g. the Nerv worker pre-installs the TypeScript toolchain in a separate stage to keep the final layer lean).

Because `run_job.sh` pre-builds the worker image before the supervisor starts, subsequent runs with the same `project_type` reuse the cached image entirely.

### Improvement options at scale

- **Package cache volume** — mount a persistent cache volume into the worker (e.g. `~/.npm` for Node, `~/.nuget/packages` for .NET) to avoid re-downloading packages across runs.
- **Warm worker pools** — pre-start idle workers with the repo pre-cloned and dependencies pre-installed; jobs skip straight to build/test.
- **MicroVM isolation** — replace Docker containers with Firecracker microVMs (e.g. via Kata Containers) for stronger isolation with comparable startup times (~125ms per VM).
- **Registry mirror** — route `npm install` through a local Verdaccio instance to eliminate external network latency.

Stack-specific timings are documented in each project's README.

---

## Results Layout

Every run produces:

```
/sandbox/results/          # in-container path (results volume)
├── result.json
└── logs/
    ├── install.log
    ├── build.log
    ├── test.log
    └── run.log        # if the agent starts the service
```

Results are copied to the host at the end of each run:

```
run_results/
└── <project_type>/
    └── <run-id>/
        ├── result.json
        ├── supervisor.log
        └── logs/
```

`result.json` schema:

```json
{
  "status": "success",
  "build_exit_code": 0,
  "test_exit_code": 0,
  "healthcheck_status": 200,
  "duration_seconds": 63,
  "run_id": "sandbox-1717612345"
}
```

The results volume persists after the run. Clean up when done:

```bash
docker volume rm <run-id>-results <run-id>-workspace
```

---

## Agent-Oriented Design

This sandbox is **not a CI pipeline**. It provides an isolated environment with the right runtime, a cloned workspace, and a way to execute arbitrary commands. The AI agent decides what to install, build, test, and run by reading the project's own manifests (`package.json`, `Dockerfile`, etc.).

Any script that infers build/test/run commands and executes them is a **harness simulation** — a demonstration of what an agent would do. These live in `examples/` and are not mounted into the sandbox.

Each project ships a `CLAUDE.md` describing its standard workflow (install → build → test → start), health endpoint, key files, and failure signals. The supervisor copies it into the workspace as `AGENT_GUIDE.md` so a real agent finds it during normal workspace inspection alongside `package.json` and other manifests.

General agent guidance (workspace inspection strategy, command protocol, failure interpretation) lives in the top-level `CLAUDE.md`.
