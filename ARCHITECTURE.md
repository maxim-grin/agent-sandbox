# Architecture

## Overview

AI agent sandbox: isolated Docker environment where an agent drives build/test/run commands against a cloned repo. Two runner modes — **harness** (scripted EXEC protocol) and **agent** (OpenHands LLM, autonomous). Supervisor and worker stacks are pluggable; OpenHands replaces the scripted harness for unknown repos.

---

## Harness Mode — Job Lifecycle

```mermaid
sequenceDiagram
    participant H as Harness Script
    participant R as run_job.sh
    participant S as Supervisor
    participant W as Worker Stack

    H->>R: job spec JSON {project_type, repo_url, commit}
    R->>R: build supervisor + worker images
    R->>R: create network, workspace vol, results vol
    R->>S: docker run -i (supervisor container)
    S->>S: parse job spec
    S->>S: clone repo → workspace volume
    S->>W: docker compose up (worker + data services)
    W-->>S: healthcheck passes
    S-->>H: SANDBOX_READY

    loop Agent command loop
        H->>S: EXEC <label> <cmd>
        S->>W: docker exec --user sandboxuser sh -c <cmd>
        W-->>S: stdout/stderr → logs/<label>.log
        S-->>H: EXIT_CODE <label> <code>

        H->>S: HEALTHCHECK <url>
        S-->>H: HEALTHCHECK_STATUS <code>
    end

    H->>S: DONE
    S->>S: write result.json
    S->>W: docker compose down -v
    R->>R: copy results → run_results/<project>/<run_id>/
    R->>R: rm network + volumes
```

---

## Agent Mode — Job Lifecycle

```mermaid
sequenceDiagram
    participant U as User
    participant R as run_agent.sh
    participant G as git (alpine)
    participant O as OpenHands
    participant DS as Data Services

    U->>R: job spec JSON + .env (LLM credentials)
    R->>R: create network, workspace vol, results vol
    R->>G: docker run — clone repo → workspace volume
    R->>DS: docker compose --profile agent up (data services)
    R->>O: docker compose --profile agent up (OpenHands)
    O->>O: read workspace manifests
    O->>O: infer runtime, deps, build, test, start, healthcheck
    O->>DS: connect (Redis, PostgreSQL, …)
    O->>O: execute pipeline autonomously
    O->>O: write result.json → /sandbox/results/
    O-->>R: container exits
    R->>R: copy results → run_results/<project>/<run_id>/
    R->>R: rm network + volumes
```

---

## Container Topology (per run)

```mermaid
graph LR
    subgraph HOST["Host"]
        hs["run_job.sh\nor run_agent.sh"]
        hr["run_results/\n  result.json\n  logs/"]
    end

    subgraph DOCKER["Docker — isolated per RUN_ID"]
        subgraph NET["Sandbox Network"]
            SUP["Supervisor\ncontainer\n(harness mode)"]

            subgraph STACK["Worker Stack  (project_type)"]
                W["Worker container\n(language toolchain)\n(harness mode)"]
                DS["Data service(s)\n(Redis / PostgreSQL)"]
                OH["OpenHands\ncontainer\n(agent mode)"]
            end
        end

        WV[("workspace\nvolume")]
        RV[("results\nvolume")]
    end

    hs -->|"harness: docker run -i\n+ Docker socket :ro"| SUP
    hs -->|"agent: docker compose\n--profile agent"| OH
    SUP -->|"git clone →"| WV
    SUP -->|"docker compose up"| STACK
    SUP -->|"docker exec worker"| W
    SUP -->|"result.json + logs"| RV

    OH -->|"reads manifests"| WV
    OH -->|"result.json + logs"| RV
    OH --- DS

    W <-->|"/workspace"| WV
    W <-->|"/sandbox/results"| RV
    W --- DS

    RV -->|"copy-out"| hr
```

---

## Component Responsibilities

| Component | Mode | Responsibility |
|-----------|------|---------------|
| `run_job.sh` | harness | Build images; create network + volumes; run supervisor; copy results; teardown |
| `run_agent.sh` | agent | Load `.env`; clone repo; start compose `--profile agent`; wait for OpenHands exit; copy results; teardown |
| `supervisor/entrypoint.sh` | harness | Parse job spec; clone repo; start stack; EXEC/HEALTHCHECK/DONE loop; write `result.json`; teardown |
| `lib/clone.sh` | harness | `git clone` repo at commit into workspace volume |
| `lib/orchestrate.sh` | harness | `docker compose up/down`; wait for worker healthcheck |
| `lib/exec.sh` | harness | `docker exec --user sandboxuser` with per-step timeout; stream to log |
| `lib/capture.sh` | harness | Write structured `result.json` |
| `projects/<type>/worker/Dockerfile` | harness | Language toolchain image (non-root `sandboxuser` UID 1001) |
| `projects/<type>/docker-compose.yml` | both | Worker + data services (default); OpenHands service (`profiles: [agent]`) |
| `agent/prompts/pipeline_task.txt` | agent | Task prompt; injected as `TASK` env var into OpenHands command |
| `.example.env` / `.env` | agent | LLM credentials: `LLM_MODEL`, `GROQ_API_KEY`, `LLM_BASE_URL` |

---

## Worker Stacks

| Stack | Worker | Data Services | Notes |
|-------|--------|---------------|-------|
| `nerv` | Node 20 Alpine | Redis 7 | `REDIS_URL=redis://redis:6379` |
| `medplum` | Node 22 Alpine | PostgreSQL 16 + Redis 7 | Turborepo monorepo |
| `eshoponweb` | .NET SDK 10 | None | EF Core in-memory DB; Apple Silicon compatible |

All stacks include an `openhands` service behind `profiles: [agent]` — started only by `run_agent.sh`.

---

## Security Model

| Concern | Harness mode | Agent mode |
|---------|-------------|------------|
| Docker socket | Supervisor: read-only mount (required to manage worker stack) | Not mounted — OpenHands uses local runtime |
| Code execution user | `sandboxuser` (UID 1001, non-root) via `docker exec` | OpenHands internal user (no sandboxuser enforcement) |
| Container hardening | `no-new-privileges`, `cap_drop: ALL` on worker + data services | Standard OpenHands image defaults |
| Network isolation | Dedicated bridge network per run | Same — dedicated bridge network per run |
| Filesystem access | Worker: workspace + results volumes only | OpenHands: workspace + results volumes only |

---

## Result Output

```
run_results/<project_name>/<run_id>/
├── result.json
├── supervisor.log        # harness mode
├── agent_output.log      # agent mode (OpenHands --json stream)
└── logs/
    ├── build.log
    ├── test.log
    └── ...
```

`project_name` = last segment of `repo_url` (`.git` stripped).

**Harness mode** `result.json`:

```json
{
  "run_id": "sandbox-<timestamp>",
  "status": "success | failure | timeout",
  "build_exit_code": 0,
  "test_exit_code": 0,
  "healthcheck_status": 200,
  "duration_seconds": 123,
  "steps": [
    { "label": "build", "status": "success", "exit_code": 0, "duration_seconds": 45 }
  ]
}
```

**Agent mode** `result.json` (written by OpenHands per prompt instructions):

```json
{
  "status": "success | failure",
  "build":        { "status": "...", "command": "...", "exit_code": 0,   "logs": "..." },
  "start_server": { "status": "...", "command": "...",                    "logs": "..." },
  "tests":        { "status": "...", "command": "...", "passed": 0, "failed": 0, "logs": "..." },
  "health_check": { "status": "...", "url": "...", "response_code": 200, "logs": "..." },
  "errors":       [],
  "duration_seconds": 0
}
```
