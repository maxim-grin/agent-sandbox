#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

STAGE="${1:-stage1}"

echo "[test] Running pipeline — stage: $STAGE"

START_TS=$(date +%s)
MOCK=true "$SCRIPT_DIR/run_agent.sh" "${REPO_ROOT}/job_specs/nerv.json"

# Find newest result.json written after we started
LATEST_RESULT=$(find "$REPO_ROOT/run_results/nerv" -name "result.json" \
  -newer "$SCRIPT_DIR/test_pipeline.sh" 2>/dev/null | sort -r | head -1 || true)

if [[ -z "$LATEST_RESULT" ]]; then
  # Fallback: find any result.json modified after START_TS
  LATEST_RESULT=$(find "$REPO_ROOT/run_results/nerv" -name "result.json" 2>/dev/null | \
    while read -r f; do [[ $(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f") -gt $START_TS ]] && echo "$f"; done | head -1 || true)
fi

if [[ -z "$LATEST_RESULT" ]]; then
  echo "[test] FAIL: no result.json found" >&2
  exit 1
fi

echo "[test] Checking: $LATEST_RESULT"

if ! jq . "$LATEST_RESULT" > /dev/null 2>&1; then
  echo "[test] FAIL: result.json is not valid JSON" >&2
  cat "$LATEST_RESULT" >&2
  exit 1
fi

STATUS="$(jq -r '.status' "$LATEST_RESULT")"
MESSAGE="$(jq -r '.message // ""' "$LATEST_RESULT")"

FAILED=0

if [[ "$STATUS" != "success" ]]; then
  echo "[test] FAIL: status='$STATUS', expected 'success'" >&2
  FAILED=1
fi

if [[ "$MESSAGE" != "hello from opencode" ]]; then
  echo "[test] FAIL: message='$MESSAGE', expected 'hello from opencode'" >&2
  FAILED=1
fi

if [[ $FAILED -eq 1 ]]; then
  echo "[test] result.json:" >&2
  jq . "$LATEST_RESULT" >&2
  exit 1
fi

echo "[test] PASS"
echo "[test] status='$STATUS' message='$MESSAGE'"
