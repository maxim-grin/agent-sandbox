# AI Agent Sandbox

A Docker-based execution environment for AI coding agents. The sandbox provides an isolated, reproducible workspace; the AI agent decides what to build, test, and run.

---

## Architecture

```
Host
├── run_job.sh              # builds images, creates per-run Docker resources, starts supervisor
│
└── Supervisor container    # stack-agnostic orchestrator
    ├── clones the repo into the workspace volume
    ├── starts the project's worker stack via docker compose
    ├── signals SANDBOX_READY on stdout
    └── accepts agent commands on stdin (EXEC / HEALTHCHECK / DONE)
        │
        └── Worker stack (projects/nerv/)
            ├── nerv-worker   Node 20 + TypeScript, workspace volume mounted at /workspace
            └── redis         Redis 7, in-memory only, no persistence
```

### Supervisor

The supervisor (`supervisor/`) is stack-agnostic. It knows how to:

- Accept a job spec (repo URL, project type, commit)
- Clone the repo into a clean workspace
- Select and start the right worker stack based on `project_type`
- Relay agent commands into the worker via `docker exec`
- Capture logs and write a structured `result.json`

It does **not** know anything about npm, TypeScript, or Nerv specifically.

### Projects (pluggable worker stacks)

Each subdirectory of `projects/` corresponds to a `project_type` value in the job spec.

```
projects/
├── nerv/
│   ├── docker-compose.yml   # worker + redis
│   └── worker/
│       └── Dockerfile       # Node 20, non-root user, TypeScript toolchain pre-installed
└── medplum/
    ├── docker-compose.yml   # worker + postgres + redis
    └── worker/
        └── Dockerfile       # Node 22, non-root user (Medplum ≥5.x requires Node 22+)
```

Adding a new stack means adding a new directory under `projects/` with a `docker-compose.yml` and a `worker/Dockerfile`. No changes to the supervisor are required.

---

## Job Spec

Jobs are described as a JSON file:

**Nerv:**
```json
{
  "project_type": "nerv",
  "repo_url": "https://github.com/maxim-grin/nerv",
  "commit": "main"
}
```

**Medplum:**
```json
{
  "project_type": "medplum",
  "repo_url": "https://github.com/medplum/medplum",
  "commit": "main"
}
```

| Field          | Required | Description                                              |
|----------------|----------|----------------------------------------------------------|
| `project_type` | yes      | Maps to a directory under `projects/`. `nerv` or `medplum` |
| `repo_url`     | yes      | HTTPS URL of the git repository to clone                 |
| `commit`       | no       | Branch, tag, or full SHA. Defaults to `main`             |

There are no `build_command`, `test_command`, or `run_command` fields. The sandbox provides the environment; the AI agent decides the commands.

---

## Quickstart

### Prerequisites

- Docker Engine 24+ with the Compose plugin
- `jq`

### Build and run (Nerv)

```bash
# 1. Create a job spec
cat > /tmp/nerv-job.json <<'EOF'
{
  "project_type": "nerv",
  "repo_url": "https://github.com/maxim-grin/nerv",
  "commit": "main"
}
EOF

# 2. Start the job (builds images, creates volumes, starts supervisor)
./scripts/run_job.sh /tmp/nerv-job.json
```

### Build and run (Medplum)

```bash
cat > /tmp/medplum-job.json <<'EOF'
{
  "project_type": "medplum",
  "repo_url": "https://github.com/medplum/medplum",
  "commit": "main"
}
EOF

./scripts/run_job.sh /tmp/medplum-job.json
```

`run_job.sh` streams all supervisor output to your terminal and exits with the supervisor's exit code.

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

From this point the AI harness drives the agent by writing commands to the supervisor's stdin:

| Command | Description |
|---------|-------------|
| `EXEC <label> <cmd> [args...]` | Runs `<cmd>` inside the worker as `sandboxuser`. Output is streamed and saved to `logs/<label>.log`. Labels `build` and `test` automatically populate `result.json`. |
| `HEALTHCHECK <url>` | Curls `<url>` and records the HTTP status code. |
| `DONE` | Signals successful completion; supervisor writes `result.json` and tears down. |

The supervisor prints `EXIT_CODE <label> <code>` after each `EXEC` so the harness can branch on failures.

### Example agent session

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

The agent discovers which commands to run by reading `package.json` inside `/workspace`. It is not told what to do.

---

## Clean State

Each run gets its own:

| Resource | Name | Lifecycle |
|----------|------|-----------|
| Docker network | `<run-id>` | created before supervisor starts, removed on exit |
| Workspace volume | `<run-id>-workspace` | created empty, supervisor clones into it |
| Results volume | `<run-id>-results` | created empty, survives for post-run inspection |

The workspace volume is created empty by `run_job.sh` before the supervisor starts. The supervisor clears it (`find /sandbox/workspace -mindepth 1 -delete`) before cloning, as an extra guard against volume reuse.

Redis is started with `--save "" --appendonly no` — no RDB snapshots, no AOF log. All data is in-memory and disappears when the container stops.

PostgreSQL (Medplum stack) uses a compose-managed volume (`pgdata`) that is **not** declared external. `docker compose down -v` removes it automatically, guaranteeing no database state leaks between runs.

**There is no shared state between runs.** All resources are namespaced by `run-id`.

---

## Security and Isolation

### Worker container

- Runs as non-root (`sandboxuser`, UID created in the Dockerfile)
- `--security-opt no-new-privileges` prevents privilege escalation
- All Linux capabilities dropped (`cap_drop: ALL`); only `SETUID`/`SETGID` re-added for npm child process spawning
- No access to the host filesystem beyond the two named volumes (`workspace`, `results`)
- Isolated on a per-run Docker bridge network; no access to other runs' containers

### Redis container

- All capabilities dropped
- No persistence; data cannot outlive the container
- Bound to the sandbox network only; not exposed to the host

### Supervisor container

- Runs with the Docker socket mounted read-only (`/var/run/docker.sock:ro`)
- The Docker socket grants significant host access — this is the primary trust boundary. In production this should be replaced with a rootless Docker daemon, a Docker-in-Docker sidecar, or a container runtime API (e.g. containerd) with scoped permissions.
- The `projects/` directory is mounted read-only; the supervisor cannot modify stack definitions at runtime

### Network

- Each run uses a dedicated Docker bridge network
- Containers in one run cannot reach containers from another run
- Outbound internet access from the worker is unrestricted by default (required for `npm install`). For higher-security deployments, add an egress firewall rule or route through a caching proxy (e.g. Verdaccio for npm).

---

## Resource Limits

| Container | Memory | CPU |
|-----------|--------|-----|
| Supervisor | 256 MB | 0.5 |
| Nerv worker | 1 GB | 2.0 |
| Nerv Redis | 128 MB | 0.5 |
| Medplum worker | 2 GB | 2.0 |
| Medplum PostgreSQL | 512 MB | 1.0 |
| Medplum Redis | 192 MB | 0.5 |

> **Note:** The Medplum worker uses Node 22 (not 20). Medplum ≥5.0 requires `node >=22.18.0`. The Nerv worker stays on Node 20.

Redis also enforces a soft cap via `--maxmemory` (96 MB for Nerv, 128 MB for Medplum) so it never exceeds its container limit. Medplum's Redis uses `noeviction` policy (BullMQ's preferred setting); Nerv uses `allkeys-lru`. Medplum's worker is allocated more memory to accommodate TypeScript monorepo compilation.

**What happens when limits are hit:**

- **Worker OOM**: Docker kills the container (exit code 137). The supervisor receives a non-zero exit and writes `result.json` with `"status": "failure"`. The harness should treat exit code 137 as an OOM signal.
- **CPU throttle**: The worker is slowed but not killed. Builds take longer; timeouts in the harness may fire.
- **Redis OOM**: Least-recently-used keys are evicted. If the application depends on keys that get evicted, it will see cache misses or errors — observable in `logs/run.log`.

---

## Build Performance

### Layer caching

The worker Dockerfile uses a two-stage build:

1. **Toolchain stage** — installs `typescript`, `ts-node`, `ts-node-dev` globally. This layer is cached and only rebuilt when the Node base image or the tool list changes.
2. **Runtime stage** — copies the compiled tools from stage 1 into a clean image. Project source code is never baked in; it arrives at runtime via the workspace volume.

Because the worker image is pre-built by `run_job.sh` before the supervisor starts, subsequent runs with the same `project_type` reuse the cached image and skip the build entirely.

### Observed timings (Nerv, cold start)

| Phase | Approximate time |
|-------|-----------------|
| Build supervisor image (first time) | ~15s |
| Build worker image (first time) | ~60s |
| Build supervisor/worker image (cached) | <2s |
| Clone Nerv repo | ~5s |
| `npm install` (no cache) | ~30s |
| `npm run build` | ~10s |
| `npm test` | ~15s |
| **Total (warm images, cold npm cache)** | **~65s** |

### Observed timings (Medplum, cold start)

| Phase | Approximate time |
|-------|-----------------|
| Build Medplum worker image (first time) | ~90s |
| Build Medplum worker image (cached) | <2s |
| PostgreSQL init + healthcheck | ~10s |
| Clone Medplum repo | ~30s |
| `npm install` — large monorepo, 3000+ packages (no cache) | ~120s |
| `turbo run build --filter=@medplum/server...` | ~90s |
| Migrations (auto on first test run) + `npm test` in packages/server | ~90s |
| **Total (warm images, cold pnpm cache)** | **~5–7 min** |

### How to improve further

- **npm cache volume**: mount a persistent `npm-cache` volume at `/home/sandboxuser/.npm` (Nerv) or `/tmp/.npm` (Medplum — non-root user writes to `/tmp`) to avoid re-downloading packages across runs.
- **Warm worker pools**: pre-start a pool of idle worker containers with the workspace volume pre-populated (repo cloned, `npm install` done). An incoming job skips directly to build/test.
- **MicroVM-based isolation**: replace Docker containers with Firecracker microVMs (e.g. via Kata Containers) for stronger isolation with comparable startup times (~125ms per VM).
- **Registry mirror**: route `npm install` through a local Verdaccio registry to eliminate external network latency entirely.

---

## Results Layout

Every run produces:

```
/sandbox/results/
├── result.json
└── logs/
    ├── install.log
    ├── build.log
    ├── test.log
    └── run.log        # if the agent starts the service
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

The results volume persists after the run for the harness to read. Clean it up when done:

```bash
docker volume rm <run-id>-results <run-id>-workspace
```

---

## Important: This is an Agent-Oriented Sandbox

This sandbox is **not a CI pipeline**. It does not know how to build or test Nerv. It provides:

- An isolated environment with the right runtime (Node 20, Redis)
- A cloned workspace
- A way to execute arbitrary commands

The AI agent is responsible for reading `package.json`, deciding which scripts to run, executing them in the right order, and interpreting the results.

Any script that infers build/test/run commands from `package.json` (or `pnpm-workspace.yaml`) and executes them is a **harness simulation** — a demonstration of what an agent would do, not a required part of the sandbox.

Included example harnesses:
- `scripts/run_nerv_example.sh` — simulates an agent driving the Nerv (Node/Redis) stack
- `scripts/run_medplum_example.sh` — simulates an agent driving the Medplum (Node/PostgreSQL/Redis) monorepo stack

### Guidance: limit repository inspection to build-relevant files

When the agent inspects the cloned workspace, it should **avoid a full recursive scan** of the repository tree. Reading every source file adds noise, bloats the agent's context window, and risks pulling in application-domain details that are irrelevant to building and running the project.

Instead, target only the files that directly describe how the project is built, tested, and run:

| Priority | Files to read |
|----------|--------------|
| Always | `package.json` / `Cargo.toml` / `pyproject.toml` (or equivalent manifest) |
| Always | `Dockerfile`, `docker-compose.yml`, `.dockerignore` |
| Always | `README.md`, `CONTRIBUTING.md` (top-level only) |
| If present | `tsconfig.json`, `jest.config.*`, `vitest.config.*`, `Makefile`, `.env.example` |
| If present | CI config (`.github/workflows/`, `.gitlab-ci.yml`) — reveals tested build steps |
| Skip | `src/**`, `lib/**`, `dist/**`, `node_modules/**`, test fixtures, generated files |

This keeps the agent's working context small and focused on the question it actually needs to answer: *what commands install, build, test, and start this project?*
