#!/usr/bin/env bash
# =============================================================================
# run_medplum_example.sh — EXAMPLE AI AGENT HARNESS (not core sandbox behaviour)
#
# This script SIMULATES what an AI coding agent would do after receiving
# SANDBOX_READY from the supervisor. It:
#   1. Inspects pnpm-workspace.yaml and packages/server/package.json to
#      understand the monorepo layout and available scripts.
#   2. Installs workspace dependencies with pnpm.
#   3. Writes packages/server/medplum.config.json pointing at the sandbox's
#      PostgreSQL and Redis services (a real agent infers this by reading the
#      config schema or CONTRIBUTING.md).
#   4. Builds the server package.
#   5. Runs DB migrations.
#   6. Runs the server test suite.
#   7. Starts the server and probes the health endpoint.
#   8. Sends DONE.
#
# A real AI harness would use an LLM to make these decisions; this script
# hard-codes the Medplum-specific workflow as a deterministic demonstration.
#
# Usage:
#   ./scripts/run_medplum_example.sh
#
# The script drives run_job.sh internally with a pre-built job spec for Medplum.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

JOB_SPEC="$(mktemp /tmp/medplum_job_XXXXXX.json)"
trap 'rm -f "$JOB_SPEC"' EXIT

cat > "$JOB_SPEC" <<'JSON'
{
  "project_type": "medplum",
  "repo_url":     "https://github.com/medplum/medplum",
  "commit":       "main"
}
JSON

# ── Docker resource names ──────────────────────────────────────────────────
RUN_ID="sandbox-$(date +%s)"
NETWORK_NAME="$RUN_ID"
RESULTS_VOLUME="${RUN_ID}-results"
WORKSPACE_VOLUME="${RUN_ID}-workspace"
SUPERVISOR_IMAGE="ai-sandbox-supervisor"
WORKER_IMAGE="ai-sandbox-medplum-worker"

CMD_PIPE="/tmp/${RUN_ID}-cmds"
SUP_LOG="/tmp/${RUN_ID}-sup.log"

HEALTH_PORT=8103
HEALTH_PATH="/healthcheck"

log() { echo "[harness] $*"; }

cleanup() {
  log "Cleanup: removing containers, network, volumes..."
  docker network rm "$NETWORK_NAME"    2>/dev/null || true
  docker volume rm "$RESULTS_VOLUME" "$WORKSPACE_VOLUME" 2>/dev/null || true
  rm -f "$CMD_PIPE"
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
docker build -q -t "$WORKER_IMAGE" "$REPO_ROOT/projects/medplum/worker"

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
# Includes: repo clone + PostgreSQL init + Redis startup + worker healthcheck
log "Waiting for SANDBOX_READY (clone + PostgreSQL + Redis + worker healthcheck)..."
wait_for "SANDBOX_READY" 300
READY_LINE=$(grep "SANDBOX_READY" "$SUP_LOG" | tail -1)
WORKER_NAME=$(echo "$READY_LINE" | grep -oP 'worker=\K\S+')
log "Stack ready. Worker container: $WORKER_NAME"

# ── Agent inspects the workspace ────────────────────────────────────────────
# (A real agent would call an LLM; we inspect known files deterministically.)
log "Inspecting workspace: pnpm-workspace.yaml"
send "EXEC inspect cat pnpm-workspace.yaml"
wait_for "EXIT_CODE inspect" 15

log "Inspecting workspace: packages/server/package.json"
send "EXEC inspect-server cat packages/server/package.json"
wait_for "EXIT_CODE inspect-server" 15

# ── Step 1: Install all workspace dependencies ───────────────────────────────
# --frozen-lockfile ensures reproducible installs from the committed lockfile.
log "Step 1: pnpm install"
send "EXEC install pnpm install --frozen-lockfile"
wait_for "EXIT_CODE install" 600

# ── Step 2: Write sandbox config ─────────────────────────────────────────────
# A real agent would read packages/server/medplum.config.json (or the config
# schema) and create an override pointing at the sandbox's named services.
log "Step 2: writing packages/server/medplum.config.json for sandbox services"
# Use node (always available) to write well-formed JSON without relying on jq.
CONFIG_JS='
const cfg = {
  port: 8103,
  baseUrl: "http://localhost:8103/",
  database: {
    host: "postgres",
    port: 5432,
    dbname: "medplum",
    username: "medplum",
    password: "medplum",
    ssl: false
  },
  redis: { host: "redis", port: 6379 },
  logLevel: "info"
};
require("fs").writeFileSync("packages/server/medplum.config.json", JSON.stringify(cfg, null, 2));
console.log("config written");
'
send "EXEC config node -e '$CONFIG_JS'"
wait_for "EXIT_CODE config" 15

# ── Step 3: Build the server package ─────────────────────────────────────────
log "Step 3: build @medplum/server"
send "EXEC build pnpm --filter @medplum/server build"
wait_for "EXIT_CODE build" 180

# ── Step 4: Run database migrations ──────────────────────────────────────────
log "Step 4: database migrations"
send "EXEC migrate pnpm --filter @medplum/server run migrate"
wait_for "EXIT_CODE migrate" 60

# ── Step 5: Run the server test suite ────────────────────────────────────────
log "Step 5: test @medplum/server"
send "EXEC test pnpm --filter @medplum/server test"
wait_for "EXIT_CODE test" 300

# ── Step 6: Start server in background inside worker ─────────────────────────
log "Step 6: launch server in background"
send "EXEC start-server node packages/server/dist/index.js &"
wait_for "EXIT_CODE start-server" 15

# Give the server time to bind and connect to PostgreSQL/Redis.
log "Waiting 8s for server to become ready..."
sleep 8

# ── Step 7: Probe health from supervisor (across Docker network) ──────────────
log "Step 7: healthcheck from supervisor → http://${WORKER_NAME}:${HEALTH_PORT}${HEALTH_PATH}"
send "HEALTHCHECK http://${WORKER_NAME}:${HEALTH_PORT}${HEALTH_PATH}"
wait_for "HEALTHCHECK_STATUS" 30

# ── Step 8: Also verify healthcheck from inside the worker ───────────────────
log "Step 8: verify health from inside worker"
send "EXEC health-probe curl -sf http://localhost:${HEALTH_PORT}${HEALTH_PATH}"
wait_for "EXIT_CODE health-probe" 15

# ── Done ──────────────────────────────────────────────────────────────────────
log "All steps complete. Sending DONE."
send "DONE"
wait $SUP_PID || true

# ── Print results ──────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo " SUPERVISOR OUTPUT (last 40 lines)"
echo "============================================"
tail -40 "$SUP_LOG"

echo ""
echo "============================================"
echo " result.json"
echo "============================================"
docker run --rm -v "${RESULTS_VOLUME}:/r" alpine sh -c 'cat /r/result.json' 2>/dev/null \
  || echo "(result.json not found)"

echo ""
echo "============================================"
echo " build.log"
echo "============================================"
docker run --rm -v "${RESULTS_VOLUME}:/r" alpine sh -c 'cat /r/logs/build.log 2>/dev/null || echo "(not found)"'

echo ""
echo "============================================"
echo " test.log (tail 30)"
echo "============================================"
docker run --rm -v "${RESULTS_VOLUME}:/r" alpine sh -c 'cat /r/logs/test.log 2>/dev/null || echo "(not found)"' | tail -30

echo ""
echo "============================================"
echo " start-server.log"
echo "============================================"
docker run --rm -v "${RESULTS_VOLUME}:/r" alpine sh -c 'cat /r/logs/start-server.log 2>/dev/null || echo "(not found)"'
