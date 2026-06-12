# Changelog

## [Unreleased] — Stage 3 complete (security hardening; mock + real Groq green)

## Stage 3 — Security hardening

- **Non-root worker**: `ocuser` (UID 1001) in nerv Dockerfile; opencode binary copied from `/root/.opencode/bin` to `/usr/local/bin` (root home is mode 700, inaccessible to non-root)
- **API key via Docker secret**: tmpfile (mode 0644) mounted at `/run/secrets/groq_key`; entrypoint exports as `OPENAI_API_KEY` + `GROQ_API_KEY`; key absent from `docker inspect` env
- **Workspace permissions**: `chown -R 1001:1001 /workspace` (mode 755) replacing `chmod -R 777`
- **Input validation**: `project_type` allowlist, `repo_url` must be `^https://`, `commit` alphanumeric + `._/-`
- **`THREATMODEL.md`**: 7 threats, mitigations, known gaps; `ARCHITECTURE.md` security model updated
- `read_only: true` deferred — bun writes to `/root/.local` at startup regardless of current user

Key discoveries:
- opencode install script writes to `~/.opencode/bin/`; root home (`/root/`) has mode 700 — binary is inaccessible to non-root users; must copy to `/usr/local/bin/`
- Docker standalone-mode secrets are bind-mounts; host file permissions apply inside container; non-root user requires `o+r` (mode 0644) on the secret file
- Groq provider uses `GROQ_API_KEY`; OpenAI mock provider uses `OPENAI_API_KEY`; entrypoint must export both from the same secret file

## Stage 1+2 — opencode migration + token tracking

Migrated agent from openhands to opencode. `run_agent.sh` drives opencode serve via HTTP API. No agent container. No SSH.

- **Worker**: replaced sshd+openhands with `opencode serve --hostname 127.0.0.1 --port 4096`
- **run_agent.sh**: rewritten — `POST /session` → `POST /session/:id/prompt_async` (204) → poll `result.json`
- **Mock LLM**: `scripts/mock/llm_server.py` — OpenAI Responses API SSE mock (opencode 1.17+ uses `/v1/responses` with `stream: true`, not `/v1/chat/completions`)
- **Mock compose**: `scripts/mock/docker-compose.mock.yml` + `scripts/mock/workspace/` fixture
- **Token stats**: `opencode stats --days 1` after result collected; merged into `result.json` as `session_tokens` + `session_cost`
- **Limits**: `mem_limit` + `cpus` + `cap_drop: ALL` on all containers
- **Plugin**: `@anthonyfangqing/opencode-special-edition` installed in worker image; reduces build agent system prompt + tool descriptions

Key discoveries:
- bash tool requires `{command, description}`; Docker Compose resolves relative paths in `-f overlay` relative to first file — use `${MOCK_DIR}` absolute path
- opencode uses Chat Completions format for Groq provider (`/v1/chat/completions`), Responses API for OpenAI provider (`/v1/responses`)
- **Groq TPM accounting**: Groq TPM = `input_tokens + max_tokens`; opencode hardcodes `max_tokens: 32000`; actual input is ~600–3,200 tokens but Groq charges ~32,500–36,000 against TPM limit; free tier (12k TPM) cannot run opencode regardless of prompt size — Dev tier required

---

## 2026-06-10 — openhands rate-limit handling

- Graceful Groq TPM backoff in openhands runner

## 2026-06-09 — openhands integration (nerv)

- `scripts/openhands_runner.py` driving openhands via API
- openhands in `docker-compose.yml` under `profiles: [agent]`
- Fixed: `WorkspaceState` import → upgrade to `openhands-ai` 1.6.0; `AppConfig` → `OpenHandsConfig`; `property 'runtime_initialized' has no setter`; paramiko 5.x → subprocess+native ssh; `cap_add: [SETUID, SETGID, SYS_CHROOT]` for sshd

## 2026-06-08 — architecture pivot to autonomous agent

- Design doc: supervisor→agent model
- `.example.env` for LLM credentials

## 2026-06-07 — infrastructure polish

- Per-project run results (`run_results/<project>/<run-id>/`)
- Timeouts: `TIMEOUT_TOTAL`, `TIMEOUT_EXEC`, `TIMEOUT_STACK_HEALTHY`
- `ARCHITECTURE.md` with mermaid diagrams
- Projects isolated (`projects/nerv/`, `projects/medplum/`, `projects/eshoponweb/`)

## 2026-06-06 — eshoponweb + medplum

- `projects/eshoponweb/` — .NET SDK 10, in-memory EF Core
- Medplum simulation workflow updates
- CLAUDE.md optimised for agent usage

## 2026-06-04–05 — medplum + foundation

- `projects/medplum/` — Node 22 + PostgreSQL 16 + Redis 7
- Persistent run results, step status + duration in result.json
- `projects/nerv/` — Node 20 + Redis 7
- Initial harness simulation (`examples/`)
