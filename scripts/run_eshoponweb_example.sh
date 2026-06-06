#!/usr/bin/env bash
# =============================================================================
# run_eshoponweb_example.sh — EXAMPLE AI AGENT HARNESS (not core sandbox behaviour)
#
# MVP harness for eShopOnWeb — built from README.md observations:
#   1. Restore: dotnet restore eShopOnWeb.sln (explicit sln required — the repo
#      root has multiple .sln/.dcproj files and dotnet errors without a target).
#   2. Build:   dotnet build eShopOnWeb.sln (same reason).
#   3. Unit tests (UnitTests.csproj — no DB required).
#   4. Start web app in background (in-memory DB via UseOnlyInMemoryDatabase env).
#   5. Health check: /api_health_check (registered in Program.cs).
#
# Integration and functional tests are intentionally omitted from this MVP run.
# Add them once restore/build/healthcheck are green.
#
# Key sandbox constraint: SQL Server has no ARM64 image. UseOnlyInMemoryDatabase=true
# is set in docker-compose.yml, switching EF Core to in-memory databases.
#
# Usage:
#   ./scripts/run_eshoponweb_example.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

JOB_SPEC="$(mktemp /tmp/eshoponweb_job_XXXXXX.json)"
trap 'rm -f "$JOB_SPEC"' EXIT

cat > "$JOB_SPEC" <<'JSON'
{
  "project_type": "eshoponweb",
  "repo_url":     "https://github.com/NimblePros/eShopOnWeb",
  "commit":       "main"
}
JSON

# ── Docker resource names ──────────────────────────────────────────────────
RUN_ID="sandbox-$(date +%s)"
NETWORK_NAME="$RUN_ID"
RESULTS_VOLUME="${RUN_ID}-results"
WORKSPACE_VOLUME="${RUN_ID}-workspace"
SUPERVISOR_IMAGE="ai-sandbox-supervisor"
WORKER_IMAGE="ai-sandbox-eshoponweb-worker"

CMD_PIPE="/tmp/${RUN_ID}-cmds"
SUP_LOG="/tmp/${RUN_ID}-sup.log"
HOST_RESULTS="$REPO_ROOT/run_results/$RUN_ID"

HEALTH_PORT=5000
HEALTH_PATH="/api_health_check"

log() { echo "[harness] $*"; }

cleanup() {
  log "Persisting results → $HOST_RESULTS"
  mkdir -p "$HOST_RESULTS"
  docker run --rm \
    -v "${RESULTS_VOLUME}:/r:ro" \
    -v "${HOST_RESULTS}:/out" \
    alpine sh -c 'cp -r /r/. /out/ 2>/dev/null || true' 2>/dev/null || true
  cp "$SUP_LOG" "$HOST_RESULTS/supervisor.log" 2>/dev/null || true

  log "Cleanup: stopping all containers for run $RUN_ID..."
  mapfile -t run_containers < <(docker ps -q --filter "name=${RUN_ID}" 2>/dev/null)
  if [[ ${#run_containers[@]} -gt 0 ]]; then
    docker rm -f "${run_containers[@]}" 2>/dev/null || true
  fi

  log "Cleanup: removing network and volumes..."
  docker network rm "$NETWORK_NAME"    2>/dev/null || true
  docker volume rm "$RESULTS_VOLUME" "$WORKSPACE_VOLUME" 2>/dev/null || true
  rm -f "$CMD_PIPE" "$SUP_LOG"
}
trap cleanup EXIT

mkfifo "$CMD_PIPE"

log "RUN_ID=$RUN_ID"
docker network create "$NETWORK_NAME"     > /dev/null
docker volume create  "$RESULTS_VOLUME"   > /dev/null
docker volume create  "$WORKSPACE_VOLUME" > /dev/null

# ── Build images ────────────────────────────────────────────────────────────
log "Building supervisor image..."
docker build -q -t "$SUPERVISOR_IMAGE" "$REPO_ROOT/supervisor"

log "Building worker image: $WORKER_IMAGE"
docker build -q -t "$WORKER_IMAGE" "$REPO_ROOT/projects/eshoponweb/worker"

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
  -v "$REPO_ROOT/projects":/sandbox/projects:ro \
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
# Includes: repo clone + worker container healthcheck (dotnet --version)
log "Waiting for SANDBOX_READY (clone + worker healthcheck)..."
wait_for "SANDBOX_READY" 180
READY_LINE=$(grep "SANDBOX_READY" "$SUP_LOG" | tail -1)
WORKER_NAME=$(echo "$READY_LINE" | grep -oP 'worker=\K\S+')
log "Stack ready. Worker container: $WORKER_NAME"

# ── Step 1: Restore NuGet packages ──────────────────────────────────────────
# Must specify eShopOnWeb.sln explicitly — the repo root has multiple solution
# and project files (Everything.sln, eShopOnWeb.slnx, docker-compose.dcproj)
# which cause MSB1011 when no target is given.
log "Step 1: dotnet restore eShopOnWeb.sln"
send "EXEC restore dotnet restore eShopOnWeb.sln"
wait_for "EXIT_CODE restore" 300

# ── Step 2: Build the full solution ─────────────────────────────────────────
log "Step 2: dotnet build eShopOnWeb.sln"
send "EXEC build dotnet build eShopOnWeb.sln --no-restore --configuration Debug"
wait_for "EXIT_CODE build" 300

# ── Step 3: Unit tests ───────────────────────────────────────────────────────
# Specify the .csproj directly to avoid multi-project ambiguity.
# Pure business-logic tests; no database or network required.
log "Step 3: dotnet test UnitTests"
send "EXEC test dotnet test tests/UnitTests/UnitTests.csproj --no-build --logger trx --verbosity normal"
wait_for "EXIT_CODE test" 120

# ── Step 4: Start web application + PublicApi in background ─────────────────
# ApiHealthCheck (tagged "apiHealthCheck", mapped to /api_health_check) calls
# PublicApi at http://localhost:5099/api/catalog-items (baseUrls__apiBase override in compose).
# ASPNETCORE_ENVIRONMENT=Development keeps Seq health checks disabled (appsettings.Development.json).
# PublicApi URL overridden to HTTP via ASPNETCORE_URLS; api.log goes to /tmp (writable by sandboxuser).
log "Step 4: start PublicApi on :5099 and Web on port $HEALTH_PORT"
send "EXEC start-server sh -c 'ASPNETCORE_URLS=http://0.0.0.0:5099 dotnet run --project src/PublicApi --no-build --no-launch-profile > /tmp/api.log 2>&1 & ASPNETCORE_URLS=http://0.0.0.0:5000 dotnet run --project src/Web --no-build --no-launch-profile &'"
wait_for "EXIT_CODE start-server" 15

# Both services need time to initialise EF Core in-memory databases and seed data.
log "Waiting 45s for both services to become ready..."
sleep 45

# ── Step 5: Health check ─────────────────────────────────────────────────────
# /api_health_check is registered in Program.cs via MapHealthChecks.
log "Step 5: healthcheck → http://${WORKER_NAME}:${HEALTH_PORT}${HEALTH_PATH}"
send "HEALTHCHECK http://${WORKER_NAME}:${HEALTH_PORT}${HEALTH_PATH}"
wait_for "HEALTHCHECK_STATUS" 30

log "Step 5b: verify health from inside worker"
send "EXEC health-probe curl -sf http://localhost:${HEALTH_PORT}${HEALTH_PATH}"
wait_for "EXIT_CODE health-probe" 15

# ── Done ──────────────────────────────────────────────────────────────────────
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
log "  result.json, supervisor.log, logs/{restore,build,test,start-server,api,health-probe}.log"
