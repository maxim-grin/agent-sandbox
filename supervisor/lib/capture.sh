#!/usr/bin/env bash

write_result() {
  local status="$1"
  local build_exit_code="$2"
  local test_exit_code="$3"
  local healthcheck_status="$4"
  local duration_seconds="$5"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Build steps JSON from globals populated by entrypoint.sh
  local steps_json="["
  local i
  for (( i=0; i<${#STEP_LABELS[@]}; i++ )); do
    [[ $i -gt 0 ]] && steps_json+=","
    steps_json+=$'\n    '
    steps_json+=$(printf '{"label":"%s","status":"%s","exit_code":%d,"duration_seconds":%d}' \
      "${STEP_LABELS[$i]}" "${STEP_STATUSES[$i]}" "${STEP_CODES[$i]}" "${STEP_DURATIONS[$i]}")
  done
  [[ ${#STEP_LABELS[@]} -gt 0 ]] && steps_json+=$'\n  '
  steps_json+="]"

  cat > "$RESULTS/result.json" <<EOF
{
  "run_id": "$RUN_ID",
  "timestamp": "$timestamp",
  "project_type": "$PROJECT_TYPE",
  "repo_url": "$REPO_URL",
  "commit": "$COMMIT",
  "status": "$status",
  "build_exit_code": $build_exit_code,
  "test_exit_code": $test_exit_code,
  "healthcheck_status": $healthcheck_status,
  "duration_seconds": $duration_seconds,
  "steps": $steps_json
}
EOF

  echo "[capture] result.json written: status=$status duration=${duration_seconds}s"
}
