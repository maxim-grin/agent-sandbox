#!/usr/bin/env bash
# =============================================================================
# run_nerv_example.sh — EXAMPLE AI AGENT HARNESS (not core sandbox behaviour)
#
# This script SIMULATES what an AI coding agent would do after receiving
# SANDBOX_READY from the supervisor. It:
#   1. Reads package.json to discover npm scripts (build / test / start).
#   2. Sends EXEC commands over the stdin protocol to install deps, build,
#      test, and probe the health endpoint.
#   3. Sends DONE when finished.
#
# A real AI harness would use an LLM to make these decisions; this script
# hard-codes the npm-based workflow as a deterministic demonstration.
#
# Usage:
#   ./examples/run_nerv_example.sh
#
# The script drives run_job.sh internally with a pre-built job spec for Nerv.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

JOB_SPEC="$(mktemp /tmp/nerv_job_XXXXXX.json)"
trap 'rm -f "$JOB_SPEC"' EXIT

cat > "$JOB_SPEC" <<'JSON'
{
  "project_type": "nerv",
  "repo_url":     "https://github.com/maxim-grin/nerv",
  "commit":       "main"
}
JSON

# ── Docker resource names ──────────────────────────────────────────────────
RUN_ID="sandbox-$(date +%s)"
NETWORK_NAME="$RUN_ID"
RESULTS_VOLUME="${RUN_ID}-results"
WORKSPACE_VOLUME="${RUN_ID}-workspace"
SUPERVISOR_IMAGE="ai-sandbox-supervisor"
WORKER_IMAGE="ai-sandbox-nerv-worker"
PROJECT_TYPE="nerv"

CMD_PIPE="/tmp/${RUN_ID}-cmds"
SUP_LOG="/tmp/${RUN_ID}-sup.log"
HOST_RESULTS="$REPO_ROOT/run_results/$PROJECT_TYPE/$RUN_ID"

log() { echo "[harness] $*"; }

cleanup() {
  log "Persisting results → $HOST_RESULTS"
  mkdir -p "$HOST_RESULTS"
  docker run --rm \
    -v "${RESULTS_VOLUME}:/r:ro" \
    -v "${HOST_RESULTS}:/out" \
    alpine sh -c 'cp -r /r/. /out/ 2>/dev/null || true' 2>/dev/null || true
  cp "$SUP_LOG" "$HOST_RESULTS/supervisor.log" 2>/dev/null || true

  log "Cleanup: removing containers, network, volumes..."
  docker network rm "$NETWORK_NAME"    2>/dev/null || true
  docker volume rm "$RESULTS_VOLUME" "$WORKSPACE_VOLUME" 2>/dev/null || true
  rm -f "$CMD_PIPE" "$SUP_LOG"
}
trap cleanup EXIT

mkfifo "$CMD_PIPE"

log "RUN_ID=$RUN_ID"
docker network create "$NETWORK_NAME"   > /dev/null
docker volume create  "$RESULTS_VOLUME" > /dev/null
docker volume create  "$WORKSPACE_VOLUME" > /dev/null

# ── Start supervisor ────────────────────────────────────────────────────────
log "Starting supervisor..."
docker run --rm -i \
  --name "$RUN_ID" \
  --network "$NETWORK_NAME" \
  --memory="256m" --cpus="0.5" \
  --security-opt no-new-privileges \
  -e RUN_ID="$RUN_ID" \
  -e SANDBOX_NETWORK="$NETWORK_NAME" \
  -e RESULTS_VOLUME="$RESULTS_VOLUME" \
  -e WORKSPACE_VOLUME="$WORKSPACE_VOLUME" \
  -e WORKER_IMAGE="$WORKER_IMAGE" \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v "$JOB_SPEC":/job/spec.json:ro \
  -v "$RESULTS_VOLUME":/sandbox/results \
  -v "$WORKSPACE_VOLUME":/sandbox/workspace \
  -v "$REPO_ROOT/projects/nerv":/sandbox/project:ro \
  "$SUPERVISOR_IMAGE" < "$CMD_PIPE" > "$SUP_LOG" 2>&1 &

SUP_PID=$!
exec 3>"$CMD_PIPE"   # keep write-end open so supervisor doesn't see EOF

send() { log "CMD → $*"; echo "$@" >&3; }

wait_for() {
  local pattern="$1" timeout="${2:-180}" elapsed=0
  until grep -q "$pattern" "$SUP_LOG" 2>/dev/null; do
    sleep 1; (( elapsed++ )) || true
    if (( elapsed >= timeout )); then
      log "Timeout waiting for: $pattern" >&2
      cat "$SUP_LOG" >&2
      return 1
    fi
  done
}

# ── Wait for stack to be ready ──────────────────────────────────────────────
log "Waiting for SANDBOX_READY (includes clone + Redis + worker healthcheck)..."
wait_for "SANDBOX_READY" 180
READY_LINE=$(grep "SANDBOX_READY" "$SUP_LOG" | tail -1)
WORKER_NAME=$(echo "$READY_LINE" | grep -oP 'worker=\K\S+')
log "Stack ready. Worker container: $WORKER_NAME"

# ── Agent reads package.json to discover scripts ────────────────────────────
# (A real agent would call an LLM here; we parse it with jq.)
log "Inspecting workspace: package.json"
send "EXEC inspect cat package.json"
wait_for "EXIT_CODE inspect"

# Derive npm scripts from the package.json inside the container.
# For this example we know the Nerv scripts; a real agent would infer them.
BUILD_SCRIPT="npm run build"
TEST_SCRIPT="npm test"
START_SCRIPT="node dist/src/server.js"
HEALTH_PORT=3000
HEALTH_PATH="/health"

# ── Step 1: Install dependencies ────────────────────────────────────────────
log "Step 1: npm install"
send "EXEC install npm install"
wait_for "EXIT_CODE install" 300

# ── Step 2: Build ────────────────────────────────────────────────────────────
log "Step 2: $BUILD_SCRIPT"
send "EXEC build $BUILD_SCRIPT"
wait_for "EXIT_CODE build" 120

# ── Step 3: Test ─────────────────────────────────────────────────────────────
log "Step 3: $TEST_SCRIPT"
send "EXEC test $TEST_SCRIPT"
wait_for "EXIT_CODE test" 120

# ── Step 4: Start server in background inside worker ─────────────────────────
# Background the process then exit the shell immediately so docker exec returns.
# The node process is adopted by the container's PID 1 and keeps running.
log "Step 4: launch server in background"
send "EXEC start-server $START_SCRIPT &"
wait_for "EXIT_CODE start-server" 15

# Give the server a moment to bind and connect to Redis.
log "Waiting 5s for server to become ready..."
sleep 5

# ── Step 5: Probe health from supervisor (across Docker network) ──────────────
log "Step 5: healthcheck from supervisor → http://${WORKER_NAME}:${HEALTH_PORT}${HEALTH_PATH}"
send "HEALTHCHECK http://${WORKER_NAME}:${HEALTH_PORT}${HEALTH_PATH}"
wait_for "HEALTHCHECK_STATUS" 30

# ── Step 6: Also verify /health from inside the worker ───────────────────────
log "Step 6: verify health from inside worker"
send "EXEC health-probe curl -sf http://localhost:${HEALTH_PORT}${HEALTH_PATH}"
wait_for "EXIT_CODE health-probe" 15

# ── Done ──────────────────────────────────────────────────────────────────────
# Server teardown is handled by the supervisor's `docker compose down` on DONE.
log "All steps complete. Sending DONE."
send "DONE"
wait $SUP_PID || true

# ── Print terminal summary ─────────────────────────────────────────────────
echo ""
echo "============================================"
echo " result.json"
echo "============================================"
docker run --rm -v "${RESULTS_VOLUME}:/r" alpine sh -c 'cat /r/result.json' 2>/dev/null \
  || echo "(result.json not found)"

echo ""
echo "============================================"
echo " healthcheck response"
echo "============================================"
docker run --rm -v "${RESULTS_VOLUME}:/r" alpine sh -c \
  'cat /r/logs/healthcheck_response.json 2>/dev/null || echo "(not found)"'

echo ""
echo "============================================"
echo " test.log (tail 30)"
echo "============================================"
docker run --rm -v "${RESULTS_VOLUME}:/r" alpine sh -c \
  'cat /r/logs/test.log 2>/dev/null || echo "(not found)"' | tail -30

echo ""
log "Full run artifacts saved to: $HOST_RESULTS"
log "  result.json, supervisor.log, logs/{install,build,test,start-server,healthcheck_response}.json"
