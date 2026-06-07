#!/usr/bin/env bash

STACK_PROJECT=""

start_stack() {
  local compose_file="$1"
  local project_type="$2"
  STACK_PROJECT="${RUN_ID}-${project_type}"

  echo "[orchestrate] Starting stack: $STACK_PROJECT"

  # docker compose inherits the supervisor's environment, which includes
  # RUN_ID, SANDBOX_NETWORK, WORKSPACE_VOLUME, RESULTS_VOLUME, WORKER_IMAGE.
  docker compose \
    -p "$STACK_PROJECT" \
    -f "$compose_file" \
    up -d \
    --force-recreate \
    --remove-orphans

  echo "[orchestrate] Stack up. Waiting for worker healthcheck..."
  _wait_healthy "${RUN_ID}-${project_type}-worker-1" "${TIMEOUT_STACK_HEALTHY:-120}"
}

teardown_stack() {
  if [[ -z "$STACK_PROJECT" ]]; then return; fi
  echo "[orchestrate] Tearing down stack: $STACK_PROJECT"
  docker compose -p "$STACK_PROJECT" down -v --remove-orphans 2>/dev/null || true
}

wait_for_stack() {
  local worker="${STACK_PROJECT}-worker-1"
  echo "[orchestrate] Waiting for worker: $worker"
  docker wait "$worker" 2>/dev/null || true
}

_wait_healthy() {
  local container="$1"
  local timeout="$2"
  local elapsed=0

  until [[ "$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null)" == "healthy" ]]; do
    if (( elapsed >= timeout )); then
      echo "[orchestrate] Timed out waiting for $container to become healthy." >&2
      return 1
    fi
    sleep 2
    (( elapsed += 2 ))
  done

  echo "[orchestrate] $container is healthy."
}
