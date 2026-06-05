#!/usr/bin/env bash

# Run an arbitrary command inside the worker container.
# The AI agent calls this to execute build/test/run steps.
#
# Usage: sandbox_exec <log_label> <cmd_string...>
# All words after the label are joined and run via "sh -c" so that shell
# operators (&, &&, pipes, variable expansions) work correctly.
# Returns the command's exit code; stdout+stderr go to /sandbox/results/logs/<label>.log
# and are also streamed to the supervisor's stdout for the harness to observe.
sandbox_exec() {
  local label="$1"; shift
  local cmd_str="$*"
  local log_file="$RESULTS/logs/${label}.log"
  local worker="${STACK_PROJECT}-worker-1"
  local t0 t1

  echo "[exec] Running '$cmd_str' in $worker (log: $log_file)"
  t0=$(date +%s)

  docker exec \
    --user sandboxuser \
    -e CI=true \
    -e NODE_ENV=test \
    -w /workspace \
    "$worker" \
    sh -c "$cmd_str" 2>&1 | tee "$log_file"

  local exit_code="${PIPESTATUS[0]}"
  t1=$(date +%s)
  LAST_EXEC_DURATION=$(( t1 - t0 ))
  echo "[exec] '$label' exited: $exit_code (${LAST_EXEC_DURATION}s)"
  return "$exit_code"
}
