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

mkdir -p /home/ocuser/.opencode
printf '{"plugin":["@anthonyfangqing/opencode-special-edition"]}' \
  > /home/ocuser/.opencode/opencode.json

exec opencode serve --hostname 127.0.0.1 --port 4096
