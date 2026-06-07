#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="/sandbox/workspace"
RESULTS="/sandbox/results"
PROJECT_DIR="/sandbox/project"
JOB_SPEC="/job/spec.json"

START_TIME=$(date +%s)
BUILD_EXIT_CODE=255
TEST_EXIT_CODE=255
HEALTH_STATUS=0

# Per-step tracking (populated during the command loop; read by write_result in capture.sh)
STEP_LABELS=()
STEP_CODES=()
STEP_DURATIONS=()
STEP_STATUSES=()
LAST_EXEC_DURATION=0

source /supervisor/lib/capture.sh
source /supervisor/lib/clone.sh
source /supervisor/lib/orchestrate.sh
source /supervisor/lib/exec.sh

log() { echo "[supervisor] $*"; }

finish() {
  local status=$1
  local end_time
  end_time=$(date +%s)
  local duration=$(( end_time - START_TIME ))

  write_result "$status" "$BUILD_EXIT_CODE" "$TEST_EXIT_CODE" "$HEALTH_STATUS" "$duration"
  teardown_stack

  if [[ "$status" == "success" ]]; then
    log "Done in ${duration}s."
    exit 0
  else
    log "Failed after ${duration}s." >&2
    exit 1
  fi
}

on_error() {
  log "Unexpected error on line $1" >&2
  finish "failure"
}
trap 'on_error $LINENO' ERR
trap 'log "Received SIGTERM, shutting down..."; finish "failure"' TERM

# --- Parse job spec ---
log "Reading job spec: $JOB_SPEC"
PROJECT_TYPE=$(jq -r '.project_type' "$JOB_SPEC")
REPO_URL=$(jq -r '.repo_url' "$JOB_SPEC")
COMMIT=$(jq -r '.commit // "main"' "$JOB_SPEC")

log "project_type=$PROJECT_TYPE repo=$REPO_URL commit=$COMMIT"

COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
[[ -f "$COMPOSE_FILE" ]] || { log "No compose file for project_type: $PROJECT_TYPE" >&2; exit 1; }

# --- Clean workspace ---
log "Cleaning workspace: $WORKSPACE"
find "$WORKSPACE" -mindepth 1 -delete 2>/dev/null || true
mkdir -p "$RESULTS/logs"

# --- Clone repo ---
clone_repo "$REPO_URL" "$COMMIT" "$WORKSPACE"

# --- Copy project agent guide into workspace so agent finds it ---
if [[ -f "$PROJECT_DIR/CLAUDE.md" ]]; then
  cp "$PROJECT_DIR/CLAUDE.md" "$WORKSPACE/AGENT_GUIDE.md"
  chown 1001:1001 "$WORKSPACE/AGENT_GUIDE.md"
  log "Copied CLAUDE.md → /workspace/AGENT_GUIDE.md"
fi

# --- Start worker stack ---
start_stack "$COMPOSE_FILE" "$PROJECT_TYPE"

# --- Signal readiness ---
# The harness watches stdout for this line before sending commands.
echo "SANDBOX_READY run_id=${RUN_ID} worker=${STACK_PROJECT}-worker-1"

# --- Stdin command loop ---
# Protocol (one command per line):
#
#   EXEC <label> <cmd> [args...]
#     Runs <cmd> [args] inside the worker container.
#     Output is streamed to stdout and logged to /sandbox/results/logs/<label>.log.
#     Labels "build" and "test" update BUILD_EXIT_CODE / TEST_EXIT_CODE automatically.
#     Exits with the command's exit code (non-zero does NOT terminate the loop).
#
#   HEALTHCHECK <url>
#     Probes <url> with curl and records the HTTP status in HEALTH_STATUS.
#
#   DONE
#     Finishes successfully and tears down the stack.
#
log "Waiting for agent commands on stdin..."

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -z "$line" ]] && continue

  verb="${line%% *}"
  rest="${line#* }"

  case "$verb" in
    EXEC)
      label="${rest%% *}"
      cmd="${rest#* }"
      # Capture exit code via || so ERR trap is never triggered:
      # commands in an || list are excluded from set -e / ERR trap.
      # shellcheck disable=SC2086
      code=0; sandbox_exec "$label" $cmd || code=$?
      step_status="success"; [[ $code -ne 0 ]] && step_status="failure"
      STEP_LABELS+=("$label")
      STEP_CODES+=("$code")
      STEP_DURATIONS+=("${LAST_EXEC_DURATION:-0}")
      STEP_STATUSES+=("$step_status")
      case "$label" in
        build) BUILD_EXIT_CODE=$code ;;
        test)  TEST_EXIT_CODE=$code  ;;
      esac
      echo "EXIT_CODE ${label} ${code}"
      ;;

    HEALTHCHECK)
      url="$rest"
      log "Probing healthcheck: $url"
      hc_t0=$(date +%s)
      # curl always writes %{http_code} before exiting; drop || echo 0 which
      # caused double-output ("000" + "0" = "0000") on connection failure.
      HEALTH_STATUS=$(curl -s -o "$RESULTS/logs/healthcheck_response.json" \
        -w "%{http_code}" --max-time 10 "$url" 2>/dev/null) || true
      # Normalize curl's "000" (no HTTP response) to plain 0
      [[ "$HEALTH_STATUS" == "000" || -z "$HEALTH_STATUS" ]] && HEALTH_STATUS=0
      hc_t1=$(date +%s)
      hc_dur=$(( hc_t1 - hc_t0 ))
      hc_status="failure"
      [[ "$HEALTH_STATUS" =~ ^2 ]] && hc_status="success"
      STEP_LABELS+=("healthcheck")
      STEP_CODES+=("$HEALTH_STATUS")
      STEP_DURATIONS+=("$hc_dur")
      STEP_STATUSES+=("$hc_status")
      echo "HEALTHCHECK_STATUS ${HEALTH_STATUS}"
      ;;

    DONE)
      log "Agent signalled DONE."
      finish "success"
      ;;

    *)
      log "Unknown command: $line" >&2
      ;;
  esac
done

# stdin closed without DONE — treat as failure
log "stdin closed without DONE." >&2
finish "failure"
