#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  echo "Usage: [MOCK=true|MOCK_LLM=true|MOCK_WORKSPACE=true] run_agent.sh <job_spec.json>" >&2
  exit 1
}

JOB_SPEC="${1:-}"
[[ -z "$JOB_SPEC" ]] && usage
[[ ! -f "$JOB_SPEC" ]] && { echo "Error: job spec file not found: $JOB_SPEC" >&2; exit 1; }

ENV_FILE="$REPO_ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
  echo "[run_agent] Loading env: $ENV_FILE"
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${key// }" ]] && continue
    key="${key%%[[:space:]]*}"
    [[ -z "$key" ]] && continue
    # Only set if not already in environment (CLI vars take precedence)
    [[ -v "$key" ]] || export "$key=$value"
  done < "$ENV_FILE"
fi

JOB_SPEC="$(realpath "$JOB_SPEC")"
PROJECT_TYPE="$(jq -r '.project_type' "$JOB_SPEC")"
REPO_URL="$(jq -r '.repo_url' "$JOB_SPEC")"
COMMIT="$(jq -r '.commit // "main"' "$JOB_SPEC")"
PROJECT_NAME="$(basename "$REPO_URL" .git)"

# --- Input validation ---
ALLOWED_TYPES=(nerv eshoponweb medplum)
[[ " ${ALLOWED_TYPES[*]} " =~ " ${PROJECT_TYPE} " ]] \
  || { echo "Error: unknown project_type '${PROJECT_TYPE}'. Allowed: ${ALLOWED_TYPES[*]}" >&2; exit 1; }
[[ "$REPO_URL" =~ ^https://[a-zA-Z0-9._/:-]+$ ]] \
  || { echo "Error: repo_url must be an https:// URL with safe chars: '${REPO_URL}'" >&2; exit 1; }
[[ "$COMMIT" =~ ^[a-zA-Z0-9._/-]+$ ]] \
  || { echo "Error: commit must contain only alphanumeric and ._/- chars: '${COMMIT}'" >&2; exit 1; }

COMMANDS_DIR="$REPO_ROOT/projects/$PROJECT_TYPE/commands"
[[ -d "$COMMANDS_DIR" ]] || { echo "Error: no commands dir for project_type: $PROJECT_TYPE ($COMMANDS_DIR)" >&2; exit 1; }

MOCK="${MOCK:-false}"
MOCK_LLM="${MOCK_LLM:-false}"
MOCK_WORKSPACE="${MOCK_WORKSPACE:-false}"
if [[ "$MOCK" == "true" ]]; then
  MOCK_LLM="true"
  MOCK_WORKSPACE="true"
fi
# Set mock LLM defaults before provider validation so validation passes without real keys
if [[ "$MOCK_LLM" == "true" ]]; then
  : "${LLM_PROVIDER:=openai}"
  : "${LLM_MODEL_ID:=gpt-4o-2024-08-06}"
fi
MOCK_DIR="$(realpath "$SCRIPT_DIR/mock")"
RUN_ID="sandbox-$(date +%s)"
NETWORK_NAME="$RUN_ID"
LLM_NETWORK="${RUN_ID}-llm"
RESULTS_VOLUME="${RUN_ID}-results"
WORKSPACE_VOLUME="${RUN_ID}-workspace"
HOST_RESULTS="$REPO_ROOT/run_results/$PROJECT_NAME/$RUN_ID"

COMPOSE_FILE="$REPO_ROOT/projects/$PROJECT_TYPE/docker-compose.yml"
[[ -f "$COMPOSE_FILE" ]] || { echo "Error: no compose file for project_type: $PROJECT_TYPE" >&2; exit 1; }

WORKER_CONTAINER="${RUN_ID}-${PROJECT_TYPE}-worker-1"
MOCK_COMPOSE="$SCRIPT_DIR/mock/docker-compose.mock.yml"

# --- Provider validation ---
[[ -z "${LLM_PROVIDER:-}" ]] && { echo "Error: LLM_PROVIDER is unset. Set it in .env (e.g. LLM_PROVIDER=groq)." >&2; exit 1; }
[[ -z "${LLM_MODEL_ID:-}" ]] && { echo "Error: LLM_MODEL_ID is unset. Set it in .env (e.g. LLM_MODEL_ID=llama-3.3-70b-versatile)." >&2; exit 1; }

OLLAMA_HOST="${OLLAMA_HOST:-http://host.docker.internal:11434}"
if [[ "$LLM_PROVIDER" == "ollama" ]]; then
  LLM_BASE_URL="${OLLAMA_HOST}/v1"
fi

OPENCODE_URL="http://${OPENCODE_HOST:-127.0.0.1}:${OPENCODE_PORT:-4096}"
LLM_KEY_FILE=""
OPENCODE_SERVER_PASSWORD="$(openssl rand -hex 16)"

TIMEOUT_STAGE="${TIMEOUT_STAGE:-180}"
TIMEOUT_TOTAL="${TIMEOUT_TOTAL:-1800}"

run_compose() {
  RUN_ID="$RUN_ID" SANDBOX_NETWORK="$NETWORK_NAME" LLM_NETWORK="$LLM_NETWORK" \
    RESULTS_VOLUME="$RESULTS_VOLUME" WORKSPACE_VOLUME="$WORKSPACE_VOLUME" \
    LLM_BASE_URL="${LLM_BASE_URL:-}" \
    LLM_PROVIDER="${LLM_PROVIDER}" \
    LLM_MODEL_ID="${LLM_MODEL_ID}" \
    OLLAMA_HOST="${OLLAMA_HOST}" \
    OPENCODE_HOST="${OPENCODE_HOST:-127.0.0.1}" \
    OPENCODE_PORT="${OPENCODE_PORT:-4096}" \
    LLM_KEY_FILE="${LLM_KEY_FILE}" \
    MOCK_DIR="${MOCK_DIR:-}" \
    MOCK_WORKSPACE="${MOCK_WORKSPACE}" \
    OPENCODE_SERVER_PASSWORD="${OPENCODE_SERVER_PASSWORD}" \
    docker compose "$@"
}

compose_down() {
  local args=(-p "${RUN_ID}-${PROJECT_TYPE}" -f "$COMPOSE_FILE")
  [[ "$MOCK_LLM" == "true" ]] && args+=(-f "$MOCK_COMPOSE")
  run_compose "${args[@]}" down -v 2>/dev/null || true
}

cleanup() {
  compose_down
  docker network rm "$NETWORK_NAME" 2>/dev/null || true
  docker network rm "$LLM_NETWORK" 2>/dev/null || true
  docker volume rm "$RESULTS_VOLUME" "$WORKSPACE_VOLUME" 2>/dev/null || true
  [[ -n "${LLM_KEY_FILE:-}" ]] && rm -f "$LLM_KEY_FILE"
}
trap cleanup EXIT

echo "[run_agent] Run ID:        $RUN_ID"
echo "[run_agent] Project type:  $PROJECT_TYPE"
echo "[run_agent] Project name:  $PROJECT_NAME"
echo "[run_agent] Repo URL:      $REPO_URL"
echo "[run_agent] Commit:        $COMMIT"
echo "[run_agent] MOCK_LLM:      $MOCK_LLM"
echo "[run_agent] MOCK_WORKSPACE:$MOCK_WORKSPACE"
echo "[run_agent] LLM:           $LLM_PROVIDER/$LLM_MODEL_ID"

# --- API key secret file ---
# Mode 0644: file is in /tmp with random name and deleted post-run.
# World-readable so the non-root container user (UID 1001) can read it
# via Docker standalone bind-mount (which applies host permissions).
LLM_KEY_FILE="$(mktemp)"
chmod 0644 "$LLM_KEY_FILE"
if [[ "$MOCK_LLM" == "true" ]]; then
  printf '%s' "mock" > "$LLM_KEY_FILE"
elif [[ "$LLM_PROVIDER" == "ollama" ]]; then
  printf '%s' "ollama-local" > "$LLM_KEY_FILE"
else
  printf '%s' "${LLM_API_KEY:-}" > "$LLM_KEY_FILE"
fi

# --- Ollama pre-flight check ---
if [[ "$LLM_PROVIDER" == "ollama" && "$MOCK_LLM" != "true" ]]; then
  echo "[run_agent] Probing Ollama at $OLLAMA_HOST..."
  if curl -sf --max-time 3 "$OLLAMA_HOST" > /dev/null 2>&1; then
    echo "[run_agent] Ollama reachable at $OLLAMA_HOST."
  else
    echo "[run_agent] ERROR: Ollama not reachable at $OLLAMA_HOST. Set OLLAMA_HOST or start Ollama and retry." >&2
    exit 1
  fi
fi

# --- Docker resources ---
echo "[run_agent] Creating networks: $NETWORK_NAME, $LLM_NETWORK"
docker network create "$NETWORK_NAME"
docker network create "$LLM_NETWORK"

echo "[run_agent] Creating volumes: $RESULTS_VOLUME, $WORKSPACE_VOLUME"
docker volume create "$RESULTS_VOLUME"
docker volume create "$WORKSPACE_VOLUME"

# --- Workspace setup ---
if [[ "$MOCK_WORKSPACE" == "true" ]]; then
  echo "[run_agent] Mock workspace: copying fixture..."
  docker run --rm \
    -v "${WORKSPACE_VOLUME}:/workspace" \
    -v "$SCRIPT_DIR/mock/workspace:/fixture:ro" \
    alpine sh -c 'cp -r /fixture/. /workspace/'
else
  echo "[run_agent] Cloning $REPO_URL @ $COMMIT..."
  docker run --rm \
    -v "${WORKSPACE_VOLUME}:/workspace" \
    alpine/git clone --depth=1 --branch "$COMMIT" "$REPO_URL" /workspace \
    || docker run --rm \
         -v "${WORKSPACE_VOLUME}:/workspace" \
         alpine/git \
         sh -c "git clone '$REPO_URL' /workspace && git -C /workspace checkout '$COMMIT'"
fi

# --- LLM routing ---
if [[ "$MOCK_LLM" == "true" ]]; then
  export LLM_BASE_URL="http://${RUN_ID}-mock-llm:8080/v1"
  LLM_PROVIDER="openai"
  LLM_MODEL_ID="gpt-4o-2024-08-06"
fi

docker run --rm \
  -v "${WORKSPACE_VOLUME}:/workspace" \
  alpine chown -R 1001:1001 /workspace

# --- Start compose ---
echo "[run_agent] Starting stack (provider: $LLM_PROVIDER, model: $LLM_MODEL_ID)..."
COMPOSE_ARGS=(-p "${RUN_ID}-${PROJECT_TYPE}" -f "$COMPOSE_FILE")
[[ "$MOCK_LLM" == "true" ]] && COMPOSE_ARGS+=(-f "$MOCK_COMPOSE")

run_compose "${COMPOSE_ARGS[@]}" up -d

# --- Wait for worker healthy ---
echo "[run_agent] Waiting for worker: $WORKER_CONTAINER"
DEADLINE=$(( $(date +%s) + 90 ))
while true; do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$WORKER_CONTAINER" 2>/dev/null || echo "missing")
  [[ "$STATUS" == "healthy" ]] && { echo "[run_agent] Worker healthy."; break; }
  if [[ $(date +%s) -gt $DEADLINE ]]; then
    echo "[run_agent] Worker never became healthy (last status: $STATUS)." >&2
    docker logs "$WORKER_CONTAINER" 2>&1 | tail -20 >&2
    exit 1
  fi
  echo "[run_agent] Worker status: $STATUS — waiting..."
  sleep 3
done

# --- Verify worker → mock-llm connectivity (mock LLM mode) ---
if [[ "$MOCK_LLM" == "true" ]]; then
  MOCK_HOST="${RUN_ID}-mock-llm"
  echo "[run_agent] Testing worker → mock-llm connectivity..."
  if docker exec "$WORKER_CONTAINER" wget -q -O /dev/null "http://${MOCK_HOST}:8080/health" 2>/dev/null; then
    echo "[run_agent] Connectivity OK."
  else
    echo "[run_agent] WARNING: worker cannot reach mock-llm!" >&2
  fi
fi

# --- Copy command files into worker ---
echo "[run_agent] Copying command files to worker..."
docker exec "$WORKER_CONTAINER" mkdir -p /workspace/.opencode/commands/
docker cp "$COMMANDS_DIR/." "$WORKER_CONTAINER:/workspace/.opencode/commands/"
echo "[run_agent] Commands installed: $(docker exec "$WORKER_CONTAINER" ls /workspace/.opencode/commands/ | tr '\n' ' ')"

# --- Create opencode session with auto-approve permissions ---
echo "[run_agent] Creating opencode session..."
SESSION_PAYLOAD=$(jq -n \
  --arg providerID "$LLM_PROVIDER" \
  --arg modelID "$LLM_MODEL_ID" \
  '{
    model: {id: $modelID, providerID: $providerID},
    permission: [
      {permission: "bash",               pattern: ".*", action: "allow"},
      {permission: "edit",               pattern: ".*", action: "allow"},
      {permission: "write",              pattern: ".*", action: "allow"},
      {permission: "read",               pattern: ".*", action: "allow"},
      {permission: "glob",               pattern: ".*", action: "allow"},
      {permission: "grep",               pattern: ".*", action: "allow"},
      {permission: "external_directory", pattern: ".*", action: "allow"}
    ]
  }')

SESSION_RESP=$(docker exec "$WORKER_CONTAINER" \
  curl -sf -u "opencode:${OPENCODE_SERVER_PASSWORD}" \
  -X POST "${OPENCODE_URL}/session" \
  -H "Content-Type: application/json" \
  -d "$SESSION_PAYLOAD")
SESSION_ID=$(echo "$SESSION_RESP" | jq -r '.id')
echo "[run_agent] Session ID: $SESSION_ID"

# --- Run 4-stage command loop ---
PIPELINE_START=$(date +%s)
for STAGE in discovery build tests run; do
  echo "[run_agent] ── Stage: $STAGE ──"

  CMD_PAYLOAD=$(jq -n --arg cmd "$STAGE" '{"command": $cmd, "arguments": ""}')

  HTTP_CODE=$(docker exec "$WORKER_CONTAINER" \
    curl -s -o /dev/null -w "%{http_code}" \
    -u "opencode:${OPENCODE_SERVER_PASSWORD}" \
    -X POST "${OPENCODE_URL}/session/${SESSION_ID}/command" \
    -H "Content-Type: application/json" \
    -d "$CMD_PAYLOAD" 2>&1 || echo "000")
  echo "[run_agent] Stage $STAGE command: HTTP $HTTP_CODE"

  if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "201" && "$HTTP_CODE" != "204" ]]; then
    echo "[run_agent] ERROR: Stage $STAGE failed with HTTP $HTTP_CODE." >&2
    exit 1
  fi

  # Poll for stage JSON as completion signal
  STAGE_JSON="/workspace/.pipeline/${STAGE}.json"
  echo "[run_agent] Waiting for $STAGE_JSON (up to ${TIMEOUT_STAGE}s)..."
  STAGE_DEADLINE=$(( $(date +%s) + TIMEOUT_STAGE ))
  while true; do
    if docker exec "$WORKER_CONTAINER" test -f "$STAGE_JSON" 2>/dev/null; then
      echo "[run_agent] Stage $STAGE: $STAGE_JSON found."
      break
    fi
    if [[ $(date +%s) -gt $STAGE_DEADLINE ]]; then
      echo "[run_agent] ERROR: Timeout waiting for $STAGE_JSON." >&2
      docker logs "$WORKER_CONTAINER" 2>&1 | tail -40 >&2
      if [[ "$MOCK_LLM" == "true" ]]; then
        docker logs "${RUN_ID}-mock-llm" 2>&1 | tail -20 >&2
      fi
      exit 1
    fi
    if [[ $(( $(date +%s) - PIPELINE_START )) -gt $TIMEOUT_TOTAL ]]; then
      echo "[run_agent] ERROR: Total pipeline timeout exceeded." >&2
      exit 1
    fi
    sleep 2
  done
done

# --- Collect stage JSONs and aggregate ---
echo "[run_agent] Aggregating stage results..."
mkdir -p "$HOST_RESULTS/logs"

MISSING=()
for STAGE in discovery build tests run; do
  if ! docker exec "$WORKER_CONTAINER" test -f "/workspace/.pipeline/${STAGE}.json" 2>/dev/null; then
    MISSING+=("$STAGE")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "[run_agent] ERROR: missing stage JSONs: ${MISSING[*]}" >&2
  exit 1
fi

for STAGE in discovery build tests run; do
  docker exec "$WORKER_CONTAINER" cat "/workspace/.pipeline/${STAGE}.json" > "$HOST_RESULTS/logs/${STAGE}.json"
  echo "[run_agent] Collected $STAGE.json"
done

# Determine overall status from build, tests, run
BUILD_STATUS=$(jq -r '.status // "unknown"' "$HOST_RESULTS/logs/build.json")
TESTS_STATUS=$(jq -r '.status // "unknown"' "$HOST_RESULTS/logs/tests.json")
RUN_STATUS=$(jq -r '.status // "unknown"' "$HOST_RESULTS/logs/run.json")
OVERALL_STATUS="success"
if [[ "$BUILD_STATUS" != "success" || "$TESTS_STATUS" != "success" || "$RUN_STATUS" != "success" ]]; then
  OVERALL_STATUS="failure"
fi

DISCOVERY_JSON="$(cat "$HOST_RESULTS/logs/discovery.json")"
BUILD_JSON="$(cat "$HOST_RESULTS/logs/build.json")"
TESTS_JSON="$(cat "$HOST_RESULTS/logs/tests.json")"
RUN_JSON="$(cat "$HOST_RESULTS/logs/run.json")"

jq -n \
  --arg status "$OVERALL_STATUS" \
  --argjson discovery "$DISCOVERY_JSON" \
  --argjson build "$BUILD_JSON" \
  --argjson tests "$TESTS_JSON" \
  --argjson run "$RUN_JSON" \
  '{status: $status, discovery: $discovery, build: $build, tests: $tests, run: $run}' \
  > "$HOST_RESULTS/result.json"

# --- Collect token stats via opencode stats ---
# Output uses box-drawing format: │Input   0 │, │Output  0 │, │Total Cost  $0.00 │
echo "[run_agent] Collecting token stats..."
STATS_RAW=$(docker exec "$WORKER_CONTAINER" opencode stats --days 1 2>/dev/null || true)
# || true on each line prevents grep exit-1 (no match) from killing script under set -o pipefail
INPUT=$(echo "$STATS_RAW"   | grep 'Input '     | grep -v 'Cache' | grep -oE '[0-9,]+' | head -1 | tr -d ',' || true)
OUTPUT=$(echo "$STATS_RAW"  | grep 'Output '    | grep -v 'Cache' | grep -oE '[0-9,]+' | head -1 | tr -d ',' || true)
CACHE_R=$(echo "$STATS_RAW" | grep 'Cache Read' | grep -oE '[0-9,]+' | head -1 | tr -d ',' || true)
CACHE_W=$(echo "$STATS_RAW" | grep 'Cache Write'| grep -oE '[0-9,]+' | head -1 | tr -d ',' || true)
COST=$(echo "$STATS_RAW"    | grep 'Total Cost' | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
INPUT="${INPUT:-0}"; OUTPUT="${OUTPUT:-0}"; CACHE_R="${CACHE_R:-0}"; CACHE_W="${CACHE_W:-0}"; COST="${COST:-0}"
[[ -n "$STATS_RAW" ]] \
  && echo "[run_agent] Stats: input=$INPUT output=$OUTPUT cache_r=$CACHE_R cache_w=$CACHE_W cost=\$$COST" \
  || echo "[run_agent] WARNING: opencode stats returned no output"

STAGE_TOKENS=$(jq -n \
  --argjson input   "$INPUT"  \
  --argjson output  "$OUTPUT" \
  --argjson cache_r "$CACHE_R" \
  --argjson cache_w "$CACHE_W" \
  '{input: $input, output: $output, cache_read: $cache_r, cache_write: $cache_w,
    total: ($input + $output + $cache_r + $cache_w)}')

jq --argjson tokens "$STAGE_TOKENS" \
   --argjson cost   "$COST" \
   '. + {session_tokens: $tokens, session_cost: $cost}' \
   "$HOST_RESULTS/result.json" > "$HOST_RESULTS/result.json.tmp" \
  && mv "$HOST_RESULTS/result.json.tmp" "$HOST_RESULTS/result.json"

trap - EXIT
cleanup

echo "[run_agent] Result:"
jq . "$HOST_RESULTS/result.json" 2>/dev/null || cat "$HOST_RESULTS/result.json"
echo "[run_agent] Results saved to: $HOST_RESULTS"
echo "[run_agent] Job complete."
