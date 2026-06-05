#!/usr/bin/env bash

write_result() {
  local status="$1"
  local build_exit_code="$2"
  local test_exit_code="$3"
  local healthcheck_status="$4"
  local duration_seconds="$5"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

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
  "duration_seconds": $duration_seconds
}
EOF

  echo "[capture] result.json written: status=$status duration=${duration_seconds}s"
}
