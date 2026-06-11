# Changelog

## [Unreleased] — opencode migration (Stage 1 complete)

Migrated agent from openhands to opencode. `run_agent.sh` now drives opencode serve via HTTP API. No agent container. No SSH.

- **Worker**: replaced sshd+openhands with `opencode serve --hostname 127.0.0.1 --port 4096`
- **run_agent.sh**: rewritten — `POST /session` → `POST /session/:id/prompt_async` (204) → poll `result.json`
- **Mock LLM**: `scripts/mock/llm_server.py` — OpenAI Responses API SSE mock (opencode 1.17+ uses `/v1/responses` with `stream: true`, not `/v1/chat/completions`)
- **Mock compose**: `scripts/mock/docker-compose.mock.yml` + `scripts/mock/workspace/` fixture
- **Limits**: `mem_limit` + `cpus` + `cap_drop: ALL` on all containers

Key discoveries: bash tool requires `{command, description}`; workspace needs `chmod 777` (not `chown 1001`) because `cap_drop: ALL` removes `CAP_DAC_OVERRIDE`; Docker Compose resolves relative paths in `-f overlay` relative to the first file — use `${MOCK_DIR}` absolute path.

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
