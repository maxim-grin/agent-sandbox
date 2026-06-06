#!/usr/bin/env bash
# =============================================================================
# run_eshoponweb_example.sh — EXAMPLE AI AGENT HARNESS (not core sandbox behaviour)
#
# This script SIMULATES what an AI coding agent would do after receiving
# SANDBOX_READY from the supervisor. It:
#   1. Inspects eShopOnWeb.sln and src/Web/Program.cs to understand the
#      solution layout and startup configuration.
#   2. Restores NuGet packages with dotnet restore.
#   3. Builds the full solution with dotnet build.
#   4. Runs UnitTests and IntegrationTests (both work with in-memory EF Core).
#      FunctionalTests are skipped — they require Playwright and a live browser.
#   5. Starts the web application in background (HTTP-only, port 5000).
#   6. Probes the /api_health_check endpoint from supervisor and from inside
#      the worker.
#   7. Sends DONE.
#
# Key sandbox constraint: SQL Server has no ARM64 image and cannot run on
# Apple Silicon. The application is started with UseOnlyInMemoryDatabase=true
# (set in docker-compose.yml) which switches both CatalogContext and
# AppIdentityDbContext to EF Core in-memory databases.
#
# A real AI harness would use an LLM to make these decisions; this script
# hard-codes the .NET workflow as a deterministic demonstration.
#
# Usage:
#   ./scripts/run_eshoponweb_example.sh
#
# The script drives run_job.sh internally with a pre-built job spec for
# eShopOnWeb.
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

# ── Agent inspects the workspace ────────────────────────────────────────────
# A real agent would call an LLM to read these files and decide on commands.
# Here we inspect known files deterministically.
log "Inspecting workspace: solution and project structure"
send "EXEC inspect ls -la"
wait_for "EXIT_CODE inspect" 15

send "EXEC inspect-sln cat eShopOnWeb.sln"
wait_for "EXIT_CODE inspect-sln" 15

send "EXEC inspect-web cat src/Web/Web.csproj"
wait_for "EXIT_CODE inspect-web" 15

# ── Step 1: Restore NuGet packages ──────────────────────────────────────────
# dotnet restore downloads all NuGet dependencies declared in the solution.
# The NuGet package cache lives in ~/.nuget/packages inside the container;
# a persistent cache volume (not wired here) would speed up repeated runs.
log "Step 1: dotnet restore"
send "EXEC restore dotnet restore"
wait_for "EXIT_CODE restore" 300

# ── Step 2: Build the full solution ─────────────────────────────────────────
# --no-restore skips redundant package restore; --configuration Debug is the
# default and matches what dotnet run --no-build expects.
log "Step 2: dotnet build"
send "EXEC build dotnet build --no-restore --configuration Debug"
wait_for "EXIT_CODE build" 300

# ── Step 3: Unit tests ───────────────────────────────────────────────────────
# Pure business-logic tests; no database or network required.
log "Step 3: dotnet test tests/UnitTests"
send "EXEC test dotnet test tests/UnitTests --no-build --logger trx --verbosity normal"
wait_for "EXIT_CODE test" 120

# ── Step 4: Integration tests ────────────────────────────────────────────────
# Use EF Core in-memory databases (IntegrationTests.csproj references
# Microsoft.EntityFrameworkCore.InMemory). The UseOnlyInMemoryDatabase env var
# is already set in the worker container via docker-compose.yml.
log "Step 4: dotnet test tests/IntegrationTests"
send "EXEC test-integration dotnet test tests/IntegrationTests --no-build --logger trx --verbosity normal"
wait_for "EXIT_CODE test-integration" 180

# ── Step 5: Start web application in background ──────────────────────────────
# ASPNETCORE_URLS=http://0.0.0.0:5000 is set in the worker environment
# (docker-compose.yml), so the app binds on all interfaces without HTTPS.
# --no-launch-profile prevents dotnet run from reading launchSettings.json
# (which would override the URL and enable HTTPS profiles).
# The trailing & exits the shell so the EXEC returns while the server runs.
log "Step 5: start web application on port $HEALTH_PORT"
send "EXEC start-server sh -c 'dotnet run --project src/Web --no-build --no-launch-profile &'"
wait_for "EXIT_CODE start-server" 15

# Give the server time to apply EF Core migrations (in-memory) and seed data.
log "Waiting 30s for web application to become ready..."
sleep 30

# ── Step 6: Probe health from supervisor (across Docker network) ─────────────
# eShopOnWeb maps health check endpoints in Program.cs:
#   app.MapHealthChecks("api_health_check", ...)
#   app.MapHealthChecks("home_page_health_check", ...)
log "Step 6: healthcheck from supervisor → http://${WORKER_NAME}:${HEALTH_PORT}${HEALTH_PATH}"
send "HEALTHCHECK http://${WORKER_NAME}:${HEALTH_PORT}${HEALTH_PATH}"
wait_for "HEALTHCHECK_STATUS" 30

# ── Step 7: Verify health from inside the worker ─────────────────────────────
log "Step 7: verify health from inside worker"
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
log "  result.json, supervisor.log, logs/{restore,build,test,test-integration,start-server,health-probe}.log"
