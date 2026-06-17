#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "[test] Running pipeline (mock mode)..."

START_TS=$(date +%s)
MOCK=true "$SCRIPT_DIR/run_agent.sh" "${REPO_ROOT}/job_specs/nerv.json"

# Find newest run directory written after we started
LATEST_RUN_DIR=$(find "$REPO_ROOT/run_results/nerv" -mindepth 1 -maxdepth 1 -type d \
  2>/dev/null | while read -r d; do
    mtime=$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null || echo 0)
    [[ "$mtime" -gt "$START_TS" ]] && echo "$d"
  done | sort -r | head -1 || true)

if [[ -z "$LATEST_RUN_DIR" ]]; then
  echo "[test] FAIL: no run directory found under run_results/nerv" >&2
  exit 1
fi

echo "[test] Checking: $LATEST_RUN_DIR"

FAILED=0

# --- Assert result.json exists and is valid JSON ---
RESULT="$LATEST_RUN_DIR/result.json"
if [[ ! -f "$RESULT" ]]; then
  echo "[test] FAIL: result.json missing" >&2
  FAILED=1
elif ! jq . "$RESULT" > /dev/null 2>&1; then
  echo "[test] FAIL: result.json is not valid JSON" >&2
  cat "$RESULT" >&2
  FAILED=1
fi

# --- Assert result.json contains all four stage keys ---
if [[ $FAILED -eq 0 ]]; then
  for KEY in discovery build tests run; do
    if ! jq -e ".$KEY" "$RESULT" > /dev/null 2>&1; then
      echo "[test] FAIL: result.json missing key '$KEY'" >&2
      FAILED=1
    fi
  done
fi

# --- Assert all four stage JSONs exist in logs/ ---
for STAGE in discovery build tests run; do
  STAGE_FILE="$LATEST_RUN_DIR/logs/${STAGE}.json"
  if [[ ! -f "$STAGE_FILE" ]]; then
    echo "[test] FAIL: stage JSON missing: logs/${STAGE}.json" >&2
    FAILED=1
  elif ! jq . "$STAGE_FILE" > /dev/null 2>&1; then
    echo "[test] FAIL: logs/${STAGE}.json is not valid JSON" >&2
    FAILED=1
  else
    echo "[test] OK: logs/${STAGE}.json"
  fi
done

# --- Assert field presence in each stage JSON ---
if [[ $FAILED -eq 0 ]]; then
  DISC="$LATEST_RUN_DIR/logs/discovery.json"
  for FIELD in install_cmd build_cmd; do
    if ! jq -e ".$FIELD | type == \"string\"" "$DISC" > /dev/null 2>&1; then
      echo "[test] FAIL: discovery.json missing string field '$FIELD'" >&2
      FAILED=1
    else
      echo "[test] OK: discovery.$FIELD"
    fi
  done

  BUILD="$LATEST_RUN_DIR/logs/build.json"
  if ! jq -e '.exit_code | type == "number"' "$BUILD" > /dev/null 2>&1; then
    echo "[test] FAIL: build.json missing number field 'exit_code'" >&2
    FAILED=1
  else
    echo "[test] OK: build.exit_code"
  fi
  if ! jq -e '.status == "success"' "$BUILD" > /dev/null 2>&1; then
    echo "[test] FAIL: build.json status != 'success'" >&2
    FAILED=1
  else
    echo "[test] OK: build.status"
  fi

  TESTS="$LATEST_RUN_DIR/logs/tests.json"
  for FIELD in passed failed; do
    if ! jq -e ".$FIELD | type == \"number\"" "$TESTS" > /dev/null 2>&1; then
      echo "[test] FAIL: tests.json missing number field '$FIELD'" >&2
      FAILED=1
    else
      echo "[test] OK: tests.$FIELD"
    fi
  done

  RUN="$LATEST_RUN_DIR/logs/run.json"
  if ! jq -e '.response_code | type == "number"' "$RUN" > /dev/null 2>&1; then
    echo "[test] FAIL: run.json missing number field 'response_code'" >&2
    FAILED=1
  else
    echo "[test] OK: run.response_code"
  fi
  if ! jq -e '.status == "success"' "$RUN" > /dev/null 2>&1; then
    echo "[test] FAIL: run.json status != 'success'" >&2
    FAILED=1
  else
    echo "[test] OK: run.status"
  fi
fi

# --- Assert overall status is success ---
if [[ $FAILED -eq 0 ]]; then
  STATUS="$(jq -r '.status' "$RESULT")"
  if [[ "$STATUS" != "success" ]]; then
    echo "[test] FAIL: result.json status='$STATUS', expected 'success'" >&2
    jq . "$RESULT" >&2
    FAILED=1
  fi
fi

if [[ $FAILED -eq 1 ]]; then
  echo "[test] FAIL"
  exit 1
fi

echo "[test] PASS"
echo "[test] All four stage JSONs present and result.json aggregated correctly."
