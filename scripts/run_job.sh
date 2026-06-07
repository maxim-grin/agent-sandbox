#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  echo "Usage: run_job.sh <job_spec.json>" >&2
  exit 1
}

JOB_SPEC="${1:-}"
[[ -z "$JOB_SPEC" ]] && usage
[[ ! -f "$JOB_SPEC" ]] && { echo "Error: job spec file not found: $JOB_SPEC" >&2; exit 1; }

# Load .env from repo root if present (allows overriding timeout defaults)
ENV_FILE="$REPO_ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
  echo "[run_job] Loading env: $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

JOB_SPEC="$(realpath "$JOB_SPEC")"
PROJECT_TYPE="$(jq -r '.project_type' "$JOB_SPEC")"

RUN_ID="sandbox-$(date +%s)"
NETWORK_NAME="$RUN_ID"
RESULTS_VOLUME="${RUN_ID}-results"
WORKSPACE_VOLUME="${RUN_ID}-workspace"
SUPERVISOR_IMAGE="ai-sandbox-supervisor"
WORKER_IMAGE="ai-sandbox-${PROJECT_TYPE}-worker"
HOST_RESULTS="$REPO_ROOT/run_results/$PROJECT_TYPE/$RUN_ID"

cleanup() {
  echo "[run_job] Persisting results → $HOST_RESULTS"
  mkdir -p "$HOST_RESULTS"
  docker run --rm \
    -v "${RESULTS_VOLUME}:/r:ro" \
    -v "${HOST_RESULTS}:/out" \
    alpine sh -c 'cp -r /r/. /out/ 2>/dev/null || true' 2>/dev/null || true

  echo "[run_job] Cleaning up network and volumes: $NETWORK_NAME"
  docker network rm "$NETWORK_NAME" 2>/dev/null || true
  docker volume rm "$RESULTS_VOLUME" "$WORKSPACE_VOLUME" 2>/dev/null || true
}
trap cleanup EXIT

echo "[run_job] Run ID:       $RUN_ID"
echo "[run_job] Project type: $PROJECT_TYPE"
echo "[run_job] Job spec:     $JOB_SPEC"

# --- Build images ---
echo "[run_job] Building supervisor image..."
docker build -q -t "$SUPERVISOR_IMAGE" "$REPO_ROOT/supervisor"

WORKER_DOCKERFILE="$REPO_ROOT/projects/$PROJECT_TYPE/worker"
[[ -d "$WORKER_DOCKERFILE" ]] || { echo "Error: no worker directory for project_type: $PROJECT_TYPE" >&2; exit 1; }
echo "[run_job] Building worker image: $WORKER_IMAGE"
docker build -q -t "$WORKER_IMAGE" "$WORKER_DOCKERFILE"

# --- Per-run Docker resources ---
echo "[run_job] Creating network: $NETWORK_NAME"
docker network create "$NETWORK_NAME"

echo "[run_job] Creating volumes: $RESULTS_VOLUME, $WORKSPACE_VOLUME"
docker volume create "$RESULTS_VOLUME"
docker volume create "$WORKSPACE_VOLUME"

# --- Run supervisor ---
# The supervisor clones the repo into WORKSPACE_VOLUME, starts the worker stack
# (which also mounts WORKSPACE_VOLUME), then signals SANDBOX_READY.
# The AI harness then drives the agent via the stdin command protocol:
#
#   EXEC <label> <cmd> [args...]   — run a command in the worker, stream output
#   DONE                           — shut down cleanly and write result.json
#
echo "[run_job] Starting supervisor..."
docker run --rm -i \
  --name "$RUN_ID" \
  --network "$NETWORK_NAME" \
  --memory="256m" \
  --cpus="0.5" \
  --security-opt no-new-privileges \
  -e RUN_ID="$RUN_ID" \
  -e SANDBOX_NETWORK="$NETWORK_NAME" \
  -e RESULTS_VOLUME="$RESULTS_VOLUME" \
  -e WORKSPACE_VOLUME="$WORKSPACE_VOLUME" \
  -e WORKER_IMAGE="$WORKER_IMAGE" \
  -e TIMEOUT_TOTAL="${TIMEOUT_TOTAL:-1800}" \
  -e TIMEOUT_EXEC="${TIMEOUT_EXEC:-600}" \
  -e TIMEOUT_STACK_HEALTHY="${TIMEOUT_STACK_HEALTHY:-120}" \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -v "$JOB_SPEC":/job/spec.json:ro \
  -v "$RESULTS_VOLUME":/sandbox/results \
  -v "$WORKSPACE_VOLUME":/sandbox/workspace \
  -v "$REPO_ROOT/projects/$PROJECT_TYPE":/sandbox/project:ro \
  "$SUPERVISOR_IMAGE"

STATUS=$?

if [[ $STATUS -eq 0 ]]; then
  echo "[run_job] Job succeeded."
else
  echo "[run_job] Job failed (exit code: $STATUS)." >&2
fi

echo "[run_job] Results will be saved to: $HOST_RESULTS"

exit $STATUS
