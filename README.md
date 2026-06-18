# AI Agent Pipeline

Docker sandbox where an opencode LLM agent autonomously builds, tests, and runs arbitrary repos. Generic across stacks via pluggable project definitions.

---

## Architecture

```
run_agent.sh (host)
  ↓  docker exec curl  →  opencode serve (worker container, 127.0.0.1:4096)
                           ↓ LLM calls (Groq / Ollama / mock)
                           ↓ bash tool executions
                           ↓ writes /workspace/.pipeline/<stage>.json
  ↑  polls /workspace/.pipeline/<stage>.json per stage
```

One container per run: **worker** (project runtime + opencode binary). No agent container. No SSH. `run_agent.sh` drives stages via HTTP API calls into the worker.

### Projects (pluggable stacks)

```
projects/
├── nerv/        Node 20 + Redis
├── medplum/     Node 22 + PostgreSQL + Redis
└── eshoponweb/  .NET SDK 10
```

Each project: `docker-compose.yml` + `worker/Dockerfile` + `commands/` (4 stage files: discovery, build, tests, run).

---

## Quickstart

### Prerequisites

- Docker Engine 24+ with Compose plugin
- `jq`
- `python3` (mock mode only)

### 1. Configure

```bash
cp .env.example .env
# edit .env — set LLM_API_KEY
```

`.env` fields:

```bash
LLM_PROVIDER=groq
LLM_MODEL_ID=llama-3.3-70b-versatile
LLM_API_KEY=gsk_...
LLM_BASE_URL=https://api.groq.com/openai/v1
```

**Ollama (local):** Set `LLM_PROVIDER=ollama`, `LLM_MODEL_ID=<model>`. `LLM_BASE_URL` is derived automatically from `OLLAMA_HOST` (default: `http://host.docker.internal:11434`). No `LLM_API_KEY` required.

### 2. Build worker image (first run only)

```bash
docker build -t ai-sandbox-nerv-worker projects/nerv/worker/
```

### 3. Run

**Mock mode** — no API key, no network, deterministic:

```bash
MOCK=true ./scripts/run_agent.sh job_specs/nerv.json
```

`MOCK=true` sets both `MOCK_LLM=true` and `MOCK_WORKSPACE=true`. Use granular flags independently:

| Flag | Effect |
|------|--------|
| `MOCK_LLM=true` | Skips real LLM; routes to local mock server |
| `MOCK_WORKSPACE=true` | Skips repo clone; uses fixture workspace |

**Real LLM** — uses Groq API:

```bash
./scripts/run_agent.sh job_specs/nerv.json
```

Results in `run_results/nerv/<run-id>/result.json`.

---

## How It Works

### Runner lifecycle (`scripts/run_agent.sh`)

1. Parse job spec → derive `PROJECT_TYPE`, `REPO_URL`, `COMMIT`
2. Create per-run Docker networks (`<run-id>` sandbox + `<run-id>-llm` egress) and volumes
3. Clone repo into workspace volume (shallow `--depth=1`)  
   — mock mode: copy `scripts/mock/workspace/` fixture instead
4. Start compose stack: worker + data services  
   — mock mode: also start `scripts/mock/docker-compose.mock.yml` (mock LLM server)
5. Wait for worker healthcheck (`GET /global/health → {healthy:true}`)
6. `POST /session` → session ID (with auto-approve permission rules)
7. `POST /session/:id/command { command: "<stage>" }` → 200/201/204, stage runs; repeat for each of 4 stages
8. Poll `/workspace/.pipeline/<stage>.json` until present (`TIMEOUT_STAGE` deadline per stage, `TIMEOUT_TOTAL` overall)
9. Collect per-stage JSONs via `docker exec cat`, aggregate → `result.json`; tear down

### Mock mode

`MOCK_LLM=true` starts a mock LLM compose service (`scripts/mock/docker-compose.mock.yml`) and points `LLM_BASE_URL` at it. `MOCK_WORKSPACE=true` copies the fixture workspace (`scripts/mock/workspace/`) instead of cloning a real repo.

Mock server (`scripts/mock/llm_server.py`) implements OpenAI Responses API with SSE streaming:

| Request | Response |
|---------|----------|
| No tools (title gen) | Text SSE: "Mock session title" |
| Tools, no prior stage result | Function call SSE: `bash` → writes `/workspace/.pipeline/<stage>.json` |
| Tools + tool result | Text SSE: "Done." |

---

## Job Spec

```json
{
  "project_type": "nerv",
  "repo_url": "https://github.com/maxim-grin/nerv",
  "commit": "main"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `project_type` | yes | Maps to `projects/<type>/` |
| `repo_url` | yes | HTTPS git URL |
| `commit` | no | Branch, tag, or SHA. Default: `main` |

---

## Result

```
run_results/
└── <project_name>/
    └── <run-id>/
        └── result.json
```

Result schema:

```json
{
  "status": "success|failure",
  "discovery": { "status": "...", "logs": "..." },
  "build":     { "status": "...", "exit_code": 0, "logs": "..." },
  "tests":     { "status": "...", "passed": 0, "failed": 0, "logs": "..." },
  "run":       { "status": "...", "response_code": 200, "logs": "..." },
  "session_tokens": { "input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "total": 0 },
  "session_cost": 0.0
}
```

---

## Security

- `cap_drop: ALL` + `no-new-privileges:true` on all containers
- Worker runs as non-root `ocuser` (UID 1001) — LLM-driven code never executes as root
- API key delivered via Docker secret (tmpfile, mode 0644, deleted post-run) — absent from `docker inspect` env
- Workspace owned by `ocuser:ocgroup` (mode 755) — no world-writable paths
- Input validation on `project_type`, `repo_url`, `commit` before any Docker operations
- opencode serve binds to `127.0.0.1:4096` only — unreachable from other containers
- No Docker socket in worker — cannot spawn containers
- Per-run networks and volumes — complete state isolation between runs

---

## Adding a New Stack

Five things needed — see `CLAUDE.md` for full spec:

1. `projects/<type>/worker/Dockerfile` — runtime + opencode binary
2. `projects/<type>/worker/docker-entrypoint.sh` — copy from `projects/shared/docker-entrypoint.sh`; reads API key from `/run/secrets/llm_key`, exports as `OPENAI_API_KEY`, then `exec opencode serve --hostname 127.0.0.1 --port 4096`
3. `projects/<type>/docker-compose.yml` — worker + data services, external networks/volumes
4. `projects/<type>/commands/` — 4 stage command files: `discovery.md`, `build.md`, `tests.md`, `run.md`; each with `subtask: true` frontmatter
5. Add `"<type>"` to enum in `schemas/job_spec.schema.json`

Worker container **must** be named `${RUN_ID}-<type>-worker-1`.

---

## Timeouts

| Variable | Default | Controls |
|----------|---------|----------|
| `TIMEOUT_STAGE` | `180s` | Poll deadline per stage (waits for `/workspace/.pipeline/<stage>.json`) |
| `TIMEOUT_TOTAL` | `1800s` | Overall run deadline (wraps all 4 stages) |

Set via env before running: `TIMEOUT_STAGE=300 TIMEOUT_TOTAL=3600 ./scripts/run_agent.sh job_specs/nerv.json`
