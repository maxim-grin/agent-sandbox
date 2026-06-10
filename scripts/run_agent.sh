#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  echo "Usage: run_agent.sh <job_spec.json>" >&2
  exit 1
}

JOB_SPEC="${1:-}"
[[ -z "$JOB_SPEC" ]] && usage
[[ ! -f "$JOB_SPEC" ]] && { echo "Error: job spec file not found: $JOB_SPEC" >&2; exit 1; }

ENV_FILE="$REPO_ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
  echo "[run_agent] Loading env: $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

JOB_SPEC="$(realpath "$JOB_SPEC")"
PROJECT_TYPE="$(jq -r '.project_type' "$JOB_SPEC")"
REPO_URL="$(jq -r '.repo_url' "$JOB_SPEC")"
COMMIT="$(jq -r '.commit // "main"' "$JOB_SPEC")"

PROJECT_NAME="$(basename "$REPO_URL" .git)"

RUN_ID="sandbox-$(date +%s)"
NETWORK_NAME="$RUN_ID"
LLM_NETWORK="${RUN_ID}-llm"
RESULTS_VOLUME="${RUN_ID}-results"
WORKSPACE_VOLUME="${RUN_ID}-workspace"
HOST_RESULTS="$REPO_ROOT/run_results/$PROJECT_NAME/$RUN_ID"

COMPOSE_FILE="$REPO_ROOT/projects/$PROJECT_TYPE/docker-compose.yml"
[[ -f "$COMPOSE_FILE" ]] || { echo "Error: no compose file for project_type: $PROJECT_TYPE" >&2; exit 1; }

PROMPT_FILE="$REPO_ROOT/projects/$PROJECT_TYPE/prompt.txt"
[[ -f "$PROMPT_FILE" ]] || { echo "Error: no prompt file for project_type: $PROJECT_TYPE (expected $PROMPT_FILE)" >&2; exit 1; }

OPENHANDS_CONTAINER="${RUN_ID}-${PROJECT_TYPE}-openhands"

cleanup() {
  echo "[run_agent] Capturing OpenHands logs..."
  mkdir -p "$HOST_RESULTS"
  docker logs "$OPENHANDS_CONTAINER" > "$HOST_RESULTS/agent_output.log" 2>&1 || true

  echo "[run_agent] Persisting results → $HOST_RESULTS"
  docker run --rm \
    -v "${RESULTS_VOLUME}:/r:ro" \
    -v "${HOST_RESULTS}:/out" \
    alpine sh -c 'cp -r /r/. /out/ 2>/dev/null || true' 2>/dev/null || true

  echo "[run_agent] Tearing down compose..."
  RUN_ID="$RUN_ID" SANDBOX_NETWORK="$NETWORK_NAME" LLM_NETWORK="${LLM_NETWORK:-}" \
    RESULTS_VOLUME="$RESULTS_VOLUME" WORKSPACE_VOLUME="$WORKSPACE_VOLUME" WORKER_IMAGE="" \
    TASK="${TASK:-}" RUNNER_SCRIPT="${RUNNER_SCRIPT:-/dev/null}" \
    LLM_MODEL="${LLM_MODEL:-}" GROQ_API_KEY="${GROQ_API_KEY:-}" LLM_BASE_URL="${LLM_BASE_URL:-}" \
    docker compose \
      -p "${RUN_ID}-${PROJECT_TYPE}" \
      -f "$COMPOSE_FILE" \
      down -v 2>/dev/null || true

  echo "[run_agent] Cleaning up networks and volumes: $NETWORK_NAME, $LLM_NETWORK"
  docker network rm "$NETWORK_NAME" 2>/dev/null || true
  docker network rm "${LLM_NETWORK:-}" 2>/dev/null || true
  docker volume rm "$RESULTS_VOLUME" "$WORKSPACE_VOLUME" 2>/dev/null || true
}
trap cleanup EXIT

echo "[run_agent] Run ID:       $RUN_ID"
echo "[run_agent] Project type: $PROJECT_TYPE"
echo "[run_agent] Project name: $PROJECT_NAME"
echo "[run_agent] Repo URL:     $REPO_URL"
echo "[run_agent] Commit:       $COMMIT"
echo "[run_agent] Job spec:     $JOB_SPEC"

# --- Docker resources ---
echo "[run_agent] Creating networks: $NETWORK_NAME, $LLM_NETWORK"
docker network create "$NETWORK_NAME"
docker network create "$LLM_NETWORK"

echo "[run_agent] Creating volumes: $RESULTS_VOLUME, $WORKSPACE_VOLUME"
docker volume create "$RESULTS_VOLUME"
docker volume create "$WORKSPACE_VOLUME"

# --- Clone repo ---
echo "[run_agent] Cloning $REPO_URL @ $COMMIT..."
docker run --rm \
  -v "${WORKSPACE_VOLUME}:/workspace" \
  alpine/git clone --depth=1 --branch "$COMMIT" "$REPO_URL" /workspace \
  || docker run --rm \
       -v "${WORKSPACE_VOLUME}:/workspace" \
       alpine/git \
       sh -c "git clone '$REPO_URL' /workspace && git -C /workspace checkout '$COMMIT'"

echo "[run_agent] Fixing workspace ownership..."
docker run --rm \
  -v "${WORKSPACE_VOLUME}:/workspace" \
  alpine chown -R 1001:1001 /workspace

# --- Load task prompt ---
TASK="$(cat "$PROMPT_FILE")"
export TASK
export RUNNER_SCRIPT="$REPO_ROOT/scripts/openhands_runner.py"

# Copy prompt into results volume so OpenHands can read it via -f (avoids
# multi-line string quoting issues when passing through docker compose env).
echo "[run_agent] Copying prompt to results volume..."
docker run --rm \
  -v "${RESULTS_VOLUME}:/r" \
  -v "${PROMPT_FILE}:/prompt.txt:ro" \
  alpine cp /prompt.txt /r/prompt.txt

# --- Start compose ---
echo "[run_agent] Starting stack..."
RUN_ID="$RUN_ID" SANDBOX_NETWORK="$NETWORK_NAME" LLM_NETWORK="$LLM_NETWORK" \
  RESULTS_VOLUME="$RESULTS_VOLUME" WORKSPACE_VOLUME="$WORKSPACE_VOLUME" \
  WORKER_IMAGE="ai-sandbox-${PROJECT_TYPE}-worker" \
  TASK="$TASK" RUNNER_SCRIPT="$RUNNER_SCRIPT" \
  LLM_MODEL="${LLM_MODEL:-}" GROQ_API_KEY="${GROQ_API_KEY:-}" LLM_BASE_URL="${LLM_BASE_URL:-}" \
  docker compose \
    -p "${RUN_ID}-${PROJECT_TYPE}" \
    -f "$COMPOSE_FILE" \
    up -d

# --- Wait for OpenHands to finish ---
echo "[run_agent] Waiting for OpenHands container: $OPENHANDS_CONTAINER"
EXIT_CODE=0
timeout "${TIMEOUT_TOTAL:-1800}" docker wait "$OPENHANDS_CONTAINER" || EXIT_CODE=$?

echo "[run_agent] OpenHands exited with code: $EXIT_CODE"

# Cleanup runs via trap — results copied there.
# Print summary if result.json exists.
RESULT_JSON="$HOST_RESULTS/result.json"

# Force cleanup now so result.json is copied before we read it.
trap - EXIT
cleanup

if [[ -f "$RESULT_JSON" ]]; then
  echo "[run_agent] Result summary:"
  jq '{status, build: .build.status, tests: .tests.status, health_check: .health_check.status, duration_seconds, session_cost, session_tokens}' "$RESULT_JSON" 2>/dev/null || cat "$RESULT_JSON"
else
  echo "[run_agent] No result.json found in $HOST_RESULTS" >&2
fi

echo "[run_agent] Results saved to: $HOST_RESULTS"

[[ $EXIT_CODE -eq 0 ]] && echo "[run_agent] Job succeeded." || { echo "[run_agent] Job failed (exit code: $EXIT_CODE)." >&2; exit $EXIT_CODE; }
