# AI Agent Sandbox

## Response style

Respond like smart caveman. Cut all filler, keep technical substance.

- Drop articles (a, an, the), filler (just, really, basically, actually).
- Drop pleasantries (sure, certainly, happy to).
- No hedging. Fragments fine. Short synonyms.
- Technical terms stay exact. Code blocks unchanged.
- Pattern: [thing] [action] [reason]. [next step].

## General Notes

- Don't scan `.git` — no useful info there.
- Pipe Bash log reads through `head`, `tail`, or `grep`. Never `cat` large files — use `Read` with `offset`/`limit`.

## Pipeline Run Procedure

End-to-end pipeline run:

1. **Single run** only.
2. Concise report: passed, failed, root causes, fix options.
3. **Stop** — don't re-run with fix applied. Ask user first.

---

## Two Runner Modes

| Mode | Runner | Who decides commands | When to use |
|------|--------|----------------------|-------------|
| **Harness** | example scripts | Harness script (hardcoded or scripted) | Deterministic demo, debugging |
| **Agent** | `scripts/run_agent.sh` | OpenHands LLM agent (autonomous) | Real AI evaluation of unknown repos |

Both modes share: same Docker network/volume pattern, same `run_results/{project}/{runid}/` output, same `result.json` schema.

---

## Adding a New Project Stack

Five things to create — no supervisor changes needed.

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

Worker + data services (existing pattern) **plus** OpenHands service for agent mode:

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

  openhands:
    image: openhands/openhands:latest
    profiles: [agent]
    container_name: "${RUN_ID}-<type>-openhands"
    environment:
      - LLM_MODEL=${LLM_MODEL}
      - LLM_API_KEY=${GROQ_API_KEY}
      - LLM_BASE_URL=${LLM_BASE_URL}
      - LLM_USE_JSON_MODE=true
      - OPENHANDS_ALWAYS_APPROVE=true
      - TASK=${TASK}
    volumes:
      - workspace:/workspace
      - results:/sandbox/results
    networks: [sandbox]
    stdin_open: true
    tty: true
    command: >-
      openhands --headless --json --always-approve
      -t "${TASK}" --workspace /workspace

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

`profiles: [agent]` means: supervisor's `docker compose up -d` (no profile) does NOT start OpenHands. Only `run_agent.sh` (passes `--profile agent`) starts it.

### 3. `projects/<type>/prompt.txt`

Agent task prompt for this stack. Include: runtime version, data service URLs (env vars already set), known quirks (e.g. monorepo build flags, health check route, test database setup). See existing prompts for format.

### 4. Schema + harness example script

- Add `"<type>"` to `project_type` enum in `schemas/job_spec.schema.json`.
- Add `examples/run_<type>_example.sh` matching existing examples: build images, create Docker resources, start supervisor, send EXEC/HEALTHCHECK/DONE commands, print result summary.

### Key invariants

- **Worker container name** must be `${RUN_ID}-<type>-worker-1`. Supervisor hardcodes this in `orchestrate.sh` and `exec.sh`.
- **OpenHands container name** follows `${RUN_ID}-<type>-openhands`. `run_agent.sh` uses this to wait for exit.
- **Network and volumes are external** — runner creates before compose, destroys after. Never `driver: local`.
- **Non-root only (worker)** — commands run as `sandboxuser` (UID 1001). OpenHands runs as its own user (accepted trade-off).
- **EXEC word-splitting** — `sandbox_exec` joins args with `$*`, passes to `sh -c`. Shell operators work. Args with spaces need `env VAR=val cmd` quoting.

---

## OpenHands Agent Runner

### Config

Copy `.example.env` → `.env`, fill in keys:

```bash
LLM_MODEL=groq/llama-3.1-8b-instant
GROQ_API_KEY=
LLM_BASE_URL=https://api.groq.com/openai/v1
```

`.env` is gitignored. `.example.env` is committed.

### Prompt

Task prompt lives in `projects/<project_type>/prompt.txt` — one file per project type. Not hardcoded in YAML.  
`run_agent.sh` reads `projects/${PROJECT_TYPE}/prompt.txt` → exports `TASK` env var → compose substitutes into command. Errors if no prompt file exists for the given project type.

### Running

```bash

./scripts/run_agent.sh job_specs/nerv.json
```

Runner: creates network/volumes → clones repo → starts compose with `--profile agent` → waits for OpenHands exit → copies results → tears down.

### Results

```
run_results/{project_name}/{runid}/
  result.json        ← written by OpenHands (prompt instructs format)
  agent_output.log   ← captured stdout (OpenHands --json stream)
```

`project_name` derived from `repo_url` (last path segment, strip `.git`).

### result.json schema (agent mode)

```json
{
  "status": "success|failure",
  "build":        { "status": "...", "command": "...", "exit_code": 0, "logs": "..." },
  "start_server": { "status": "...", "command": "...", "logs": "..." },
  "tests":        { "status": "...", "command": "...", "passed": 0, "failed": 0, "logs": "..." },
  "health_check": { "status": "...", "url": "...", "response_code": 200, "logs": "..." },
  "errors":       [],
  "duration_seconds": 0
}
```

---

## Harness Mode: Driving the Sandbox (EXEC protocol)

Used by example scripts (`examples/run_*_example.sh`).

Once `SANDBOX_READY` prints, write commands to supervisor stdin:

- `EXEC <label> <cmd> [args...]` — run command in worker; output → `logs/<label>.log`
- `HEALTHCHECK <url>` — curl URL, record HTTP status
- `DONE` — signal success; supervisor writes `result.json` and tears down

Supervisor replies `EXIT_CODE <label> <code>` after each `EXEC`. Branch on non-zero before continuing.

### Workspace inspection (for harness scripts)

Avoid full recursive scan. Target only files describing build/test/run:

| Priority   | Files to read |
|------------|---------------|
| Always     | `package.json` / `Cargo.toml` / `pyproject.toml` |
| Always     | `Dockerfile`, `docker-compose.yml` |
| Always     | `README.md`, `CONTRIBUTING.md` (top-level only) |
| If present | `tsconfig.json`, `jest.config.*`, `Makefile`, `.env.example` |
| If present | CI config (`.github/workflows/`, `.gitlab-ci.yml`) |
| Skip       | `src/**`, `lib/**`, `dist/**`, `node_modules/**`, test fixtures |

### Interpreting failures

- Exit code **137** = OOM kill. Needs more memory or leaner build.
- Non-zero `test_exit_code` in `result.json` = tests failed; read `logs/test.log`.
- `healthcheck_status` not 200 = service didn't start; read `logs/run.log`.

---

## Architecture

Docker-based AI agent sandbox. Execution env for AI coding agents, not CI. Generic across stacks.

Design priorities: **single sandbox + pluggable stacks**, **separate data services per stack**, **clean state per run**, **non-interactive execution**, **structured output capture**.

### Sandbox responsibilities

- Isolated, reproducible env: supervisor + stack containers, dedicated Docker network + volumes per run.
- Lifecycle + clean state: fresh workspace, fresh data per run.
- Enforce: non-interactive, security/isolation, resource limits.
- Capture: logs, structured `result.json`.

### Agent responsibilities

- Inspect repo manifests (`package.json`, `Dockerfile`, `docker-compose.yml`, docs).
- Figure out how to install deps, build, run tests, start service, probe healthcheck.
- Decide concrete commands and order.
- Execute (via EXEC protocol in harness mode; autonomously in OpenHands mode).
- Interpret logs/result and decide next steps.

> Sandbox must not hard-code project-specific build/test/run commands. Sandbox exposes env + execution; agent chooses commands from manifest files.

### Job spec

```json
{
  "project_type": "<type>",
  "repo_url": "https://github.com/<org>/<repo>",
  "commit": "main"
}
```

### Supervisor lifecycle (harness mode)

1. Parse job spec.
2. Clean workspace.
3. Clone repo at commit.
4. Select worker stack from `project_type`.
5. Orchestrate worker + data service containers.
6. Signal `SANDBOX_READY`.
7. Accept EXEC/HEALTHCHECK/DONE commands on stdin.
8. Capture logs, write `result.json`, exit.

### Results layout

```
/sandbox/results/logs/build.log
/sandbox/results/logs/test.log
/sandbox/results/logs/run.log
/sandbox/results/result.json
```

### Security

Treat worker code as untrusted.

- **Filesystem**: limit mounts to workspace + results.
- **Network**: dedicated Docker network per run.
- **Container hardening**: non-root (sandboxuser), drop caps, `no-new-privileges`.
- **Docker socket**: supervisor gets read-only socket to manage worker stack. OpenHands does not get socket (uses local runtime).

### Resource limits

Per-container CPU/memory limits defined in each `docker-compose.yml`. Exit code 137 = OOM. Supervisor timeout: `TIMEOUT_TOTAL` (default 1800s), `TIMEOUT_EXEC` (default 600s).

### Build performance

- Multi-stage builds, lean images.
- Pre-install common deps to leverage layer cache.
- Shallow clone (`--depth=1`) for fast workspace setup.
