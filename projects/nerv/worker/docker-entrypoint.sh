#!/bin/sh
set -e

SECRET_FILE="/run/secrets/groq_key"
if [ ! -f "$SECRET_FILE" ] || [ ! -s "$SECRET_FILE" ]; then
  echo "[entrypoint] ERROR: API key secret missing or empty at $SECRET_FILE" >&2
  exit 1
fi
export OPENAI_API_KEY
OPENAI_API_KEY="$(cat "$SECRET_FILE")"

# Write opencode plugin config to tmpfs-mounted home dir (not baked into image
# because the tmpfs mount shadows the build-time file at runtime).
mkdir -p /home/ocuser/.opencode
printf '{"plugin":["@anthonyfangqing/opencode-special-edition"]}' \
  > /home/ocuser/.opencode/opencode.json

exec opencode serve --hostname 127.0.0.1 --port 4096
