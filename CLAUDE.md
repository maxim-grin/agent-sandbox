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

Single runner: `scripts/run_agent.sh`. OpenHands LLM agent decides all commands autonomously via SSH into worker container.

---

## Adding a New Project Stack

Five things to create.

### 1. `projects/<type>/worker/Dockerfile`

Project runtime + SSHd. Agent SSHes into this container to run all commands.

```dockerfile
FROM <runtime-image>   # must be multi-arch if Apple Silicon support is needed

RUN <install git curl openssh and any system deps>

RUN addgroup -g 1001 sandboxgroup && adduser -u 1001 -G sandboxgroup -m sandboxuser
RUN mkdir -p /workspace /sandbox/results/logs \
    && chown -R sandboxuser:sandboxgroup /workspace /sandbox

# SSH host keys (stable across container restarts within a run)
RUN ssh-keygen -A
RUN mkdir -p /home/sandboxuser/.ssh \
    && chown sandboxuser:sandboxgroup /home/sandboxuser/.ssh \
    && chmod 700 /home/sandboxuser/.ssh

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /workspace

HEALTHCHECK --interval=5s --timeout=5s --retries=3 CMD <runtime version check>
CMD ["/usr/local/bin/docker-entrypoint.sh"]
```

### 2. `projects/<type>/worker/docker-entrypoint.sh`

Writes agent's public key, starts SSHd.

```bash
#!/bin/sh
set -e

if [ -n "${AGENT_SSH_PUBKEY:-}" ]; then
    echo "$AGENT_SSH_PUBKEY" > /home/sandboxuser/.ssh/authorized_keys
    chown sandboxuser:sandboxgroup /home/sandboxuser/.ssh/authorized_keys
    chmod 600 /home/sandboxuser/.ssh/authorized_keys
fi

exec /usr/sbin/sshd -D -e
```

### 3. `projects/<type>/docker-compose.yml`

Worker + data services + openhands agent. Two separate images — worker has project runtime, openhands has SDK only.

```yaml
services:
  worker:
    build:
      context: worker
      dockerfile: Dockerfile
    image: ai-sandbox-<type>-worker
    container_name: "${RUN_ID}-<type>-worker-1"
    networks: [sandbox, llm]    # llm needed for package installs (npm, pip, etc.)
    volumes:
      - workspace:/workspace
      - results:/sandbox/results:ro
    working_dir: /workspace
    environment:
      CI: "true"
      AGENT_SSH_PUBKEY: "${AGENT_SSH_PUBKEY}"
      # stack-specific env vars
    mem_limit: <Xg>
    cpus: <N>
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    healthcheck:
      test: ["CMD", "<version check>"]
      interval: 5s
      timeout: 5s
      retries: 3
      start_period: 10s

  # optional data service containers (postgres, redis, …)
  # data services: networks: [sandbox] only — no internet needed

  openhands:
    build:
      context: ../..
      dockerfile: docker/Dockerfile.agent
    image: ai-sandbox-agent
    container_name: "${RUN_ID}-<type>-openhands"
    environment:
      - LLM_MODEL=${LLM_MODEL}
      - LLM_API_KEY=${GROQ_API_KEY}
      - LLM_BASE_URL=${LLM_BASE_URL}
      - LLM_USE_JSON_MODE=true
      - OPENHANDS_ALWAYS_APPROVE=true
      - TASK=${TASK}
      - SSH_HOST=worker
      - SSH_USER=sandboxuser
      - SSH_KEY=/run/secrets/ssh_key
      # stack-specific vars (REDIS_URL, POSTGRES_HOST, etc.)
    volumes:
      - results:/sandbox/results
      - ${RUNNER_SCRIPT}:/app/openhands_runner.py:ro
      - ${SSH_KEY_PATH}:/run/secrets/ssh_key:ro
    working_dir: /app
    networks: [sandbox, llm]
    depends_on:
      worker: {condition: service_healthy}
      # add data service deps here
    mem_limit: 2g
    cpus: 1.0
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    stdin_open: false
    tty: false
    command: python openhands_runner.py

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
```

### 4. `projects/<type>/prompt.txt`

Agent task prompt for this stack. Include: runtime version, data service URLs (env vars already set), known quirks (e.g. monorepo build flags, health check route, test database setup). See existing prompts for format.

### 5. Schema

- Add `"<type>"` to `project_type` enum in `schemas/job_spec.schema.json`.

### Key invariants

- **Worker container name** must be `${RUN_ID}-<type>-worker-1`. `run_agent.sh` derives the worker name from this pattern.
- **OpenHands container name** follows `${RUN_ID}-<type>-openhands`. `run_agent.sh` uses this to wait for exit.
- **Network and volumes are external** — runner creates before compose, destroys after. Never `driver: local`.
- **Worker runs SSHd** — agent container SSHes in as `sandboxuser` (UID 1001) to execute all commands.
- **Results volume read-only on worker** — OpenHands agent owns `result.json` writes via direct volume mount. Worker mounts results as `:ro`.
- **Shared agent image** — `docker/Dockerfile.agent` is project-agnostic. All project types use same `ai-sandbox-agent` image.

---

## Agent Runner

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

Runner: generates SSH key pair → creates networks/volumes → clones repo → starts compose → waits for OpenHands exit → copies results → tears down.

### Results

```
run_results/{project_name}/{runid}/
  result.json        ← written by OpenHands agent (prompt instructs format), augmented with token/cost
  agent_output.log   ← captured stdout
```

`project_name` derived from `repo_url` (last path segment, strip `.git`).

### result.json schema

```json
{
  "status": "success|failure",
  "build":        { "status": "...", "command": "...", "exit_code": 0, "logs": "..." },
  "start_server": { "status": "...", "command": "...", "logs": "..." },
  "tests":        { "status": "...", "command": "...", "passed": 0, "failed": 0, "logs": "..." },
  "health_check": { "status": "...", "url": "...", "response_code": 200, "logs": "..." },
  "errors":       [],
  "duration_seconds": 0,
  "session_tokens": {
    "prompt_tokens": 0,
    "completion_tokens": 0,
    "cache_read_tokens": 0,
    "cache_write_tokens": 0
  },
  "session_cost": 0.0
}
```

`session_tokens` and `session_cost` added by `scripts/openhands_runner.py` after agent exits.

---

## Architecture

Docker-based AI agent sandbox. Execution env for AI coding agents, not CI. Generic across stacks.

Design priorities: **single sandbox + pluggable stacks**, **separate data services per stack**, **clean state per run**, **non-interactive execution**, **structured output capture**.

### Two-image design

Each run has two containers: **worker** and **openhands**.

- **Worker** (`ai-sandbox-<type>-worker`) — project runtime (Node.js, .NET, etc.) + SSHd. Receives commands from agent over SSH. Project-specific image, built from `projects/<type>/worker/Dockerfile`.
- **Openhands** (`ai-sandbox-agent`) — openhands-ai SDK + paramiko. Project-agnostic shared image built from `docker/Dockerfile.agent`. Makes LLM API calls; SSHes into worker to run all build/test/start commands.

### Sandbox responsibilities

- Isolated, reproducible env: stack containers, dedicated Docker network + volumes per run.
- Lifecycle + clean state: fresh workspace, fresh data per run.
- Enforce: non-interactive, security/isolation, resource limits.
- Capture: logs, structured `result.json`.

### Agent responsibilities

- Inspect repo manifests (`package.json`, `Dockerfile`, `docker-compose.yml`, docs).
- Figure out how to install deps, build, run tests, start service, probe healthcheck.
- Decide concrete commands and order.
- Execute autonomously via SSH into worker.
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

### Runner lifecycle

1. Parse job spec.
2. Generate ephemeral ed25519 SSH key pair (per-run, deleted in cleanup trap).
3. Create Docker networks: `${RUN_ID}` (sandbox) + `${RUN_ID}-llm` (egress).
4. Create volumes: workspace + results.
5. Clone repo at commit into workspace volume.
6. Start compose stack (worker + data services + openhands).
7. Wait for OpenHands container to exit (`timeout ${TIMEOUT_TOTAL:-1800}`).
8. Copy results to `run_results/{project}/{runid}/`.
9. Tear down compose, remove networks + volumes.

### Results layout

```
/sandbox/results/result.json
/sandbox/results/agent_output.log
```

### Security

Treat worker code as untrusted.

- **No Docker socket** — neither agent nor worker mounts `/var/run/docker.sock`. Eliminates host escape vector.
- **Filesystem** — worker mounts results read-only; openhands agent owns result writes via direct volume mount.
- **Network** — two dedicated Docker networks per run: `sandbox` (inter-container) and `llm` (egress). Worker + openhands on both (need package registry + LLM API). Data services (redis/db) on sandbox only.
- **SSH** — ephemeral ed25519 key pair generated per run. Public key passed to worker via env; private key mounted into agent container. Keys deleted in cleanup trap.
- **Container hardening** — drop caps, `no-new-privileges` on all containers; resource limits (`mem_limit` + `cpus`).
- **Run timeout** — `TIMEOUT_TOTAL` (default 1800s) wraps `docker wait`.

### Build performance

- Pre-built images (`ai-sandbox-<type>-worker`, `ai-sandbox-agent`) — compose caches between runs.
- Shallow clone (`--depth=1`) for fast workspace setup.
