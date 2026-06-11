# AI Agent Pipeline

Docker sandbox where an opencode LLM agent autonomously builds, tests, and runs arbitrary repos. Generic across stacks via pluggable project definitions.

---

## Architecture

```
run_agent.sh (host)
  ↓  docker exec curl  →  opencode serve (worker container, 127.0.0.1:4096)
                           ↓ LLM calls (Groq / mock)
                           ↓ bash tool executions
                           ↓ writes /workspace/result.json
  ↑  polls /workspace/result.json until present
```

One container per run: **worker** (project runtime + opencode binary). No agent container. No SSH. `run_agent.sh` drives stages via HTTP API calls into the worker.

### Projects (pluggable stacks)

```
projects/
├── nerv/        Node 20 + Redis
├── medplum/     Node 22 + PostgreSQL + Redis      (planned)
└── eshoponweb/  .NET SDK 10                       (planned)
```

Each project: `docker-compose.yml` + `worker/Dockerfile` + `prompt.txt`.

---

## Quickstart

### Prerequisites

- Docker Engine 24+ with Compose plugin
- `jq`
- `python3` (mock mode only)

### 1. Configure

```bash
cp .example.env .env
# edit .env — set GROQ_API_KEY
```

`.env` fields:

```bash
LLM_MODEL=groq/llama-3.3-70b-versatile   # format: providerID/modelID
GROQ_API_KEY=gsk_...
LLM_BASE_URL=https://api.groq.com/openai/v1
```

### 2. Build worker image (first run only)

```bash
docker build -t ai-sandbox-nerv-worker projects/nerv/worker/
```

### 3. Run

**Mock mode** — no API key, no network, deterministic:

```bash
MOCK=true ./scripts/run_agent.sh job_specs/nerv.json
```

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
7. `POST /session/:id/prompt_async` → 204, task runs async
8. Poll `/workspace/result.json` until present (default 180s timeout)
9. Collect result, tear down

### Mock mode

`MOCK=true` swaps the LLM endpoint:

```
OPENAI_API_KEY=mock
OPENAI_BASE_URL=http://<run-id>-mock-llm:8080/v1
LLM_PROVIDER=openai
LLM_MODEL_ID=gpt-4o-2024-08-06
```

Mock server (`scripts/mock/llm_server.py`) implements OpenAI Responses API with SSE streaming:

| Request | Response |
|---------|----------|
| No tools (title gen) | Text SSE: "Mock session title" |
| Tools, no prior result | Function call SSE: `bash` → writes `result.json` |
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

Stage 1 (current) result schema:

```json
{
  "status": "success",
  "message": "hello from opencode"
}
```

---

## Security

- `cap_drop: ALL` on all containers — no Linux capability escalation
- No Docker socket in worker — cannot spawn containers
- opencode serve binds to `127.0.0.1` only — not reachable from other containers
- API key via env (prod: Docker secret via tmpfile mount)
- Per-run networks and volumes — complete run isolation

---

## Adding a New Stack

Five things needed — see `CLAUDE.md` for full spec:

1. `projects/<type>/worker/Dockerfile` — runtime + opencode binary
2. `projects/<type>/worker/docker-entrypoint.sh` — `exec opencode serve --hostname 127.0.0.1 --port 4096`
3. `projects/<type>/docker-compose.yml` — worker + data services, external networks/volumes
4. `projects/<type>/prompt.txt` — task prompt for Stage 1
5. Add `"<type>"` to enum in `schemas/job_spec.schema.json`

Worker container **must** be named `${RUN_ID}-<type>-worker-1`.

---

## Timeouts

| Variable | Default | Controls |
|----------|---------|----------|
| `TIMEOUT_STAGE` | `180s` | Poll deadline for `result.json` |

Set via env before running: `TIMEOUT_STAGE=300 ./scripts/run_agent.sh job_specs/nerv.json`
