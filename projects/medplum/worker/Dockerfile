# syntax=docker/dockerfile:1
#
# Medplum worker image.
# Node 22 is required: Medplum >=5.x uses Promise.withResolvers, the WebSocket
# global, and other APIs that first appeared in Node 22.
# Medplum uses npm workspaces (packageManager: npm@10.x); pnpm is not needed.

FROM node:22-alpine

RUN apk add --no-cache git curl openssl

# Non-root user for all agent-driven commands (fixed UID/GID so the runner
# can chown the cloned workspace without needing sandboxuser to exist there).
RUN addgroup -S -g 1001 sandboxgroup && adduser -S -u 1001 -G sandboxgroup sandboxuser

# /workspace is mounted at runtime from the workspace volume (cloned by run_agent.sh)
RUN mkdir -p /workspace /sandbox/results/logs \
    && chown -R sandboxuser:sandboxgroup /workspace /sandbox

WORKDIR /workspace

USER sandboxuser

HEALTHCHECK --interval=5s --timeout=3s --retries=3 \
  CMD node --version

# Keeps the container alive for docker exec commands from the agent
CMD ["sleep", "infinity"]
