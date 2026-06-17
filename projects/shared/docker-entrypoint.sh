#!/bin/sh
# Canonical source: projects/shared/docker-entrypoint.sh
# Per-project copies in projects/<type>/worker/docker-entrypoint.sh must be identical.
set -e

SECRET_FILE="/run/secrets/llm_key"
if [ "$LLM_PROVIDER" = "ollama" ]; then
  : # Ollama needs no API key
else
  if [ ! -f "$SECRET_FILE" ] || [ ! -s "$SECRET_FILE" ]; then
    echo "[entrypoint] ERROR: API key secret missing or empty at $SECRET_FILE" >&2
    exit 1
  fi
  KEY="$(cat "$SECRET_FILE")"
  export OPENAI_API_KEY="$KEY"
fi

mkdir -p /home/ocuser/.opencode
BASE_CONFIG="/etc/opencode/opencode.json"

if [ "$LLM_PROVIDER" = "ollama" ]; then
  MODEL_ID="${LLM_MODEL_ID:-qwen3:0.6b}"
  OLLAMA_BASE="${OLLAMA_HOST:-http://host.docker.internal:11434}"
  jq --arg model "$MODEL_ID" --arg base "${OLLAMA_BASE}/v1" \
    '. + {"provider": {"ollama": {"npm": "@ai-sdk/openai-compatible", "name": "Ollama", "options": {"baseURL": $base}, "models": {($model): {"name": $model, "tools": true, "options": {"think": false}}}}}}' \
    "$BASE_CONFIG" > /home/ocuser/.opencode/opencode.json
else
  cp "$BASE_CONFIG" /home/ocuser/.opencode/opencode.json
fi

exec opencode serve --hostname "${OPENCODE_HOST:-127.0.0.1}" --port "${OPENCODE_PORT:-4096}"
