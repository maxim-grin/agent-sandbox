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

## Runner

Single runner: `scripts/run_agent.sh`. opencode agent drives 4-stage pipeline via HTTP API (`docker exec curl` into worker). No agent container. No SSH.

Mock mode: `MOCK=true ./scripts/run_agent.sh <job_spec>` — skips clone, uses fixture workspace, points LLM at local mock server.

---

## Adding a New Project Stack

Five things to create.

### 1. `projects/<type>/worker/Dockerfile`

Project runtime + opencode binary. Multi-stage build. Non-root user.

```dockerfile
FROM <runtime-image> AS toolchain
RUN <install runtime tools>

FROM <runtime-image> AS runtime
RUN apk add --no-cache git curl wget jq

# Install opencode as root. The install script writes to /root/.opencode/bin/ which
# is inaccessible to non-root users (/root is 700). Copy binary to /usr/local/bin.
ENV SHELL=/bin/bash
RUN curl -fsSL https://opencode.ai/install | bash && \
    cp /root/.opencode/bin/opencode /usr/local/bin/opencode && \
    chmod 755 /usr/local/bin/opencode

RUN addgroup -S -g 1001 ocgroup && adduser -S -u 1001 -G ocgroup -s /bin/sh ocuser
RUN mkdir -p /workspace /sandbox/results \
    && chown -R ocuser:ocgroup /workspace /sandbox

COPY --from=toolchain <tools> <dest>
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER ocuser
WORKDIR /workspace

HEALTHCHECK --interval=5s --timeout=5s --retries=6 \
  CMD wget -q -O /dev/null http://localhost:4096/global/health
CMD ["/usr/local/bin/docker-entrypoint.sh"]
```

### 2. `projects/<type>/worker/docker-entrypoint.sh`

Reads API key from Docker secret, starts opencode serve.

```bash
#!/bin/sh
set -e

SECRET_FILE="/run/secrets/groq_key"
if [ ! -f "$SECRET_FILE" ] || [ ! -s "$SECRET_FILE" ]; then
  echo "[entrypoint] ERROR: API key secret missing or empty at $SECRET_FILE" >&2
  exit 1
fi
KEY="$(cat "$SECRET_FILE")"
export OPENAI_API_KEY="$KEY"
export GROQ_API_KEY="$KEY"

# Write opencode config to home dir at runtime (not baked into image because
# any tmpfs mount on ~/.opencode shadows the build-time file).
mkdir -p /home/ocuser/.opencode
# Customize opencode.json here if plugins are needed.

exec opencode serve --hostname 127.0.0.1 --port 4096
```

### 3. `projects/<type>/docker-compose.yml`

Worker + data services only. No agent container.

```yaml
services:
  worker:
    build:
      context: worker
      dockerfile: Dockerfile
    image: ai-sandbox-<type>-worker
    container_name: "${RUN_ID}-<type>-worker-1"
    networks: [sandbox, llm]
    volumes:
      - workspace:/workspace
      - results:/sandbox/results:ro
    working_dir: /workspace
    environment:
      CI: "true"
      OPENAI_BASE_URL: "${LLM_BASE_URL}"
      OPENCODE_SERVER_PASSWORD: "${OPENCODE_SERVER_PASSWORD}"
      # stack-specific env vars
    secrets:
      - groq_key
    mem_limit: <Xg>
    cpus: <N>
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost:4096/global/health"]
      interval: 5s
      timeout: 5s
      retries: 6
      start_period: 15s

  # optional data services (postgres, redis, …)
  # data services: networks: [sandbox] only

networks:
  sandbox:
    external: true
    name: "${SANDBOX_NETWORK}"
  llm:
    external: true
    name: "${LLM_NETWORK}"

volumes:
  workspace:
    external: true
    name: "${WORKSPACE_VOLUME}"
  results:
    external: true
    name: "${RESULTS_VOLUME}"

secrets:
  groq_key:
    file: "${GROQ_KEY_FILE}"
```

### 4. `projects/<type>/commands/`

Four opencode command files — one per pipeline stage. Each uses `subtask: true` for context isolation.

`discovery.md`:
```markdown
---
description: Discover build/test/run commands
model: openai/llama-3.3-70b-versatile
subtask: true
---
Read /workspace/package.json (or equivalent manifest).
Write /workspace/.pipeline/discovery.json: { install_cmd, build_cmd, test_cmd, start_cmd, health_url, port }.
```

`build.md`, `tests.md`, `run.md` follow same pattern with `!cat` shell injection for prior stage output.
See existing `projects/nerv/commands/` for reference.

### 5. Schema

- Add `"<type>"` to `project_type` enum in `schemas/job_spec.schema.json`.

### Key invariants

- **Worker container name** must be `${RUN_ID}-<type>-worker-1`. `run_agent.sh` derives worker name from this pattern.
- **No agent container** — `run_agent.sh` drives stages via `docker exec curl` into worker.
- **Network and volumes are external** — runner creates before compose, destroys after. Never `driver: local`.
- **Worker runs opencode serve on 127.0.0.1:4096** — not exposed on container network interface.
- **Results volume read-only on worker** — stage JSONs written to `/workspace/.pipeline/`; collected by runner via `docker exec cat`.

---

## Agent Runner

### Config

Copy `.example.env` → `.env`, fill in keys:

```bash
LLM_MODEL=llama-3.3-70b-versatile
GROQ_API_KEY=
LLM_BASE_URL=https://api.groq.com/openai/v1
```

`.env` is gitignored. `.example.env` is committed.

### Running

```bash
./scripts/run_agent.sh job_specs/nerv.json

# mock mode (no Groq key needed)
MOCK=true ./scripts/run_agent.sh job_specs/nerv.json
```

Runner lifecycle: creates networks/volumes → clones repo → starts compose → waits for worker healthy → copies commands → creates session → runs 4-stage loop via HTTP API → aggregates results → tears down.

### Results

```
run_results/{project_name}/{runid}/
  result.json           ← aggregated from stage JSONs by run_agent.sh
  logs/
    discovery.json
    build.json
    tests.json
    run.json
```

`project_name` derived from `repo_url` (last path segment, strip `.git`).

### result.json schema

```json
{
  "status": "success|failure",
  "discovery": { "status": "...", "logs": "..." },
  "build":     { "status": "...", "exit_code": 0, "logs": "..." },
  "tests":     { "status": "...", "passed": 0, "failed": 0, "logs": "..." },
  "run":       { "status": "...", "response_code": 200, "logs": "..." },
  "errors":    [],
  "duration_seconds": 0,
  "stages": {
    "discovery": { "session_tokens": {}, "session_cost": 0.0 },
    "build":     { "session_tokens": {}, "session_cost": 0.0 },
    "tests":     { "session_tokens": {}, "session_cost": 0.0 },
    "run":       { "session_tokens": {}, "session_cost": 0.0 }
  },
  "total_cost": 0.0
}
```

---

## Architecture

Docker-based AI agent sandbox. opencode LLM agent drives 4-stage pipeline against cloned repo. Generic across stacks.

Design priorities: **single sandbox + pluggable stacks**, **separate data services per stack**, **clean state per run**, **non-interactive execution**, **structured output capture**.

### Single-container design

One container per run: **worker** (project runtime + opencode serve). `run_agent.sh` on host drives stages via `docker exec curl` HTTP API calls.

- **Worker** (`ai-sandbox-<type>-worker`) — project runtime + opencode binary + tokenscope plugin. Runs `opencode serve`. All LLM calls and bash tool execution happen inside this container.

### Sandbox responsibilities

- Isolated, reproducible env: stack containers, dedicated Docker networks + volumes per run.
- Lifecycle + clean state: fresh workspace, fresh data per run.
- Enforce: non-interactive, security/isolation, resource limits.
- Capture: structured `result.json` aggregated from stage outputs.

### Agent responsibilities

- Inspect repo manifests (`package.json`, `Dockerfile`, etc.) during discovery stage.
- Execute install, build, test, start-server commands in subsequent stages.
- Write structured JSON after each stage to `/workspace/.pipeline/`.

> Sandbox must not hard-code project-specific commands. Each stage prompt instructs the agent to read manifests and prior stage output.

### Job spec

```json
{
  "project_type": "<type>",
  "repo_url": "https://github.com/<org>/<repo>",
  "commit": "main"
}
```

### Runner lifecycle

1. Parse job spec.
2. Generate `OPENCODE_SERVER_PASSWORD` (random hex, per-run).
3. Write API key to tmpfile (`GROQ_KEY_FILE`).
4. Create Docker networks: `${RUN_ID}` (sandbox) + `${RUN_ID}-llm` (egress).
5. Create volumes: workspace + results.
6. Clone repo at commit into workspace volume.
7. Start compose stack (worker + data services).
8. Wait for worker healthcheck (`GET /global/health` → `{ healthy: true }`).
9. `docker cp` stage command files → `/workspace/.opencode/commands/`.
10. Create opencode session via `POST /session`.
11. Run 4-stage loop: `POST /session/:id/command { command: stage }` for each stage; abort on failure.
12. After each stage: run tokenscope, collect token/cost.
13. Collect stage JSONs via `docker exec cat`; aggregate → `result.json`.
14. Copy results to `run_results/{project}/{runid}/`.
15. Tear down compose, remove networks + volumes + tmpfiles.

### Security

- **No Docker socket** — worker does not mount `/var/run/docker.sock`.
- **Non-root user** — `ocuser` (UID 1001); opencode serve runs as non-root.
- **API key** — Docker secret (tmpfile mount); entrypoint reads before serve starts; never in container env.
- **Server auth** — `OPENCODE_SERVER_PASSWORD` (random per run); all `docker exec curl` calls use HTTP basic auth.
- **opencode serve bind** — `127.0.0.1` only; not reachable from other containers on same network.
- **Network** — sandbox (inter-container) + llm (egress); data services on sandbox only.
- **Container hardening** — `cap_drop: ALL`, `no-new-privileges`; no `cap_add` needed.
- **Run timeout** — `TIMEOUT_TOTAL` (default 1800s) wraps stage loop.

### Build performance

- Pre-built worker image (`ai-sandbox-<type>-worker`) — compose caches between runs.
- Shallow clone (`--depth=1`) for fast workspace setup.
