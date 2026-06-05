#!/usr/bin/env bash
# =============================================================================
# run_medplum_example.sh — EXAMPLE AI AGENT HARNESS (not core sandbox behaviour)
#
# This script SIMULATES what an AI coding agent would do after receiving
# SANDBOX_READY from the supervisor. It:
#   1. Inspects package.json and packages/server/package.json to understand
#      the monorepo layout and available scripts.
#   2. Installs workspace dependencies with npm.
#   3. Writes packages/server/medplum.config.json pointing at the sandbox's
#      PostgreSQL and Redis services (a real agent infers this by reading the
#      config schema or CONTRIBUTING.md).
#   4. Builds the server package (and its workspace dependencies) via Turbo.
#   5. Creates a start.mjs wrapper (Node.js does not set import.meta.main,
#      so the server's built index.js needs an explicit entry shim).
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

# ── Write sandbox config (direct docker exec — complex JSON, not suitable
#    for the EXEC line protocol's shell word-splitting) ────────────────────
# A real agent would read packages/server/medplum.config.json (or the config
# schema) and create an override pointing at the sandbox's named services.
log "Writing packages/server/medplum.config.json for sandbox services"
docker exec --user sandboxuser -w /workspace "$WORKER_NAME" \
  sh -c 'cat > packages/server/medplum.config.json' << 'CONFIG'
{
  "port": 8103,
  "baseUrl": "http://localhost:8103/",
  "appBaseUrl": "http://localhost:3000/",
  "binaryStorage": "file:./binary/",
  "storageBaseUrl": "http://localhost:8103/storage/",
  "supportEmail": "\"Medplum\" <support@medplum.com>",
  "googleClientId": "",
  "googleClientSecret": "",
  "recaptchaSiteKey": "",
  "recaptchaSecretKey": "",
  "botLambdaRoleArn": "",
  "botLambdaLayerName": "medplum-bot-layer",
  "vmContextBotsEnabled": true,
  "defaultBotRuntimeVersion": "vmcontext",
  "allowedOrigins": "*",
  "introspectionEnabled": true,
  "database": {
    "host": "postgres",
    "port": 5432,
    "dbname": "medplum",
    "username": "medplum",
    "password": "medplum"
  },
  "redis": {
    "host": "redis",
    "port": 6379
  },
  "bullmq": {
    "removeOnFail": { "count": 1 },
    "removeOnComplete": { "count": 1 }
  },
  "shutdownTimeoutMilliseconds": 30000
}
CONFIG

# ── Agent inspects the workspace ────────────────────────────────────────────
# (A real agent would call an LLM; we inspect known files deterministically.)
log "Inspecting workspace: package.json (monorepo root)"
send "EXEC inspect cat package.json"
wait_for "EXIT_CODE inspect" 15

log "Inspecting workspace: packages/server/package.json"
send "EXEC inspect-server cat packages/server/package.json"
wait_for "EXIT_CODE inspect-server" 15

# ── Step 1: Install all workspace dependencies ───────────────────────────────
# Medplum uses npm workspaces (packageManager: npm@10.x). npm install at the
# monorepo root installs all packages in packages/*/
log "Step 1: npm install"
send "EXEC install npm install"
wait_for "EXIT_CODE install" 600

# ── Step 2: Build the server package (and its workspace dependencies) ─────────
# Medplum uses Turborepo. --filter=@medplum/server... builds the server and all
# packages it depends on in dependency order (core, definitions, fhirpath, etc.).
# NODE_OPTIONS raises the V8 heap limit for TypeScript compilation of the
# large monorepo (~1.8 GB peak). Uses env(1) to avoid shell quoting in the
# EXEC line protocol.
log "Step 2: build @medplum/server (with dependencies via Turbo)"
send "EXEC build env NODE_OPTIONS=--max-old-space-size=1800 node_modules/.bin/turbo run build --filter=@medplum/server..."
wait_for "EXIT_CODE build" 300

# ── Create start.mjs wrapper (direct docker exec — must run after build) ─────
# Medplum's built dist/index.js guards its entrypoint with `if (import.meta.main)`,
# which is a Deno/Bun idiom. Node.js never sets import.meta.main, so the server
# would silently exit with code 0 when invoked directly. This wrapper imports
# the module dynamically (so the body executes before the module is evaluated)
# and calls runFromCli() explicitly.
log "Creating packages/server/dist/start.mjs entry wrapper"
docker exec --user sandboxuser -w /workspace "$WORKER_NAME" \
  sh -c 'cat > packages/server/dist/start.mjs' << 'SHIM'
// Node.js does not set import.meta.main (that is a Deno/Bun concept).
// Import dynamically so this assignment runs before index.js is evaluated.
const { runFromCli } = await import("./index.js");
runFromCli(process.argv).catch(console.error);
SHIM

# ── Step 3: Run the server test suite ────────────────────────────────────────
# Note: cloud/AWS/Lambda tests fail when AWS credentials are absent — that is
# expected in this sandbox environment. The core FHIR/server tests pass.
# Migrations run automatically inside initApp() when tests call initAppServices().
log "Step 3: test @medplum/server"
send "EXEC test npm --prefix packages/server test -- --testTimeout=60000 --forceExit"
wait_for "EXIT_CODE test" 600

# ── Step 4: Start server in background inside worker ─────────────────────────
log "Step 4: launch server in background"
send "EXEC start-server node packages/server/dist/start.mjs"
wait_for "EXIT_CODE start-server" 15

# Give the server time to bind and connect to PostgreSQL/Redis.
log "Waiting 10s for server to become ready..."
sleep 10

# ── Step 5: Probe health from supervisor (across Docker network) ──────────────
log "Step 5: healthcheck from supervisor → http://${WORKER_NAME}:${HEALTH_PORT}${HEALTH_PATH}"
send "HEALTHCHECK http://${WORKER_NAME}:${HEALTH_PORT}${HEALTH_PATH}"
wait_for "HEALTHCHECK_STATUS" 30

# ── Step 6: Also verify healthcheck from inside the worker ───────────────────
log "Step 6: verify health from inside worker"
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
echo " build.log (tail 20)"
echo "============================================"
docker run --rm -v "${RESULTS_VOLUME}:/r" alpine sh -c 'cat /r/logs/build.log 2>/dev/null || echo "(not found)"' | tail -20

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
