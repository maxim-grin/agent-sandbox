#!/bin/sh
set -e

SECRET_FILE="/run/secrets/groq_key"
if [ "$LLM_PROVIDER" = "ollama" ]; then
  : # Ollama provider in opencode needs no API key
else
  if [ ! -f "$SECRET_FILE" ] || [ ! -s "$SECRET_FILE" ]; then
    echo "[entrypoint] ERROR: API key secret missing or empty at $SECRET_FILE" >&2
    exit 1
  fi
  KEY="$(cat "$SECRET_FILE")"
  export OPENAI_API_KEY="$KEY"
  export GROQ_API_KEY="$KEY"
fi

# Write opencode config to tmpfs-mounted home dir (not baked into image
# because the tmpfs mount shadows the build-time file at runtime).
mkdir -p /home/ocuser/.opencode
PLUGIN="@anthonyfangqing/opencode-special-edition"
if [ "$LLM_PROVIDER" = "ollama" ]; then
  MODEL_ID="${LLM_MODEL_ID:-gemma3:1b}"
  printf '{"$schema":"https://opencode.ai/config.json","plugin":["%s"],"provider":{"ollama":{"npm":"@ai-sdk/openai-compatible","name":"Ollama","options":{"baseURL":"http://host.docker.internal:11434/v1"},"models":{"%s":{"name":"%s","tools":true,"options":{"think":false}}}}}}' \
    "$PLUGIN" "$MODEL_ID" "$MODEL_ID" \
    > /home/ocuser/.opencode/opencode.json
else
  printf '{"plugin":["%s"]}' "$PLUGIN" \
    > /home/ocuser/.opencode/opencode.json
fi

exec opencode serve --hostname 127.0.0.1 --port 4096
