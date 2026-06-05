# syntax=docker/dockerfile:1

# Stage 1: install global tools (cached layer, rebuilt only when Node version changes)
FROM node:20-alpine AS toolchain

RUN apk add --no-cache git curl

# Pre-install common TypeScript tooling so agent runs don't hit the registry
RUN npm install -g typescript ts-node ts-node-dev 2>/dev/null

# Stage 2: runtime image (no build artifacts, lean layer)
FROM node:20-alpine AS runtime

RUN apk add --no-cache git curl

# Non-root user for all agent-driven commands (fixed UID/GID so the supervisor
# can chown the cloned workspace without needing sandboxuser to exist there).
RUN addgroup -S -g 1001 sandboxgroup && adduser -S -u 1001 -G sandboxgroup sandboxuser

# Copy globally installed tools from the toolchain stage
COPY --from=toolchain /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=toolchain /usr/local/bin/tsc          /usr/local/bin/tsc
COPY --from=toolchain /usr/local/bin/ts-node      /usr/local/bin/ts-node
COPY --from=toolchain /usr/local/bin/ts-node-dev  /usr/local/bin/ts-node-dev

# /workspace is mounted at runtime from the workspace volume (cloned by supervisor)
RUN mkdir -p /workspace /sandbox/results/logs \
    && chown -R sandboxuser:sandboxgroup /workspace /sandbox

WORKDIR /workspace

USER sandboxuser

HEALTHCHECK --interval=5s --timeout=3s --retries=3 \
  CMD node --version

# Keeps the container alive for docker exec commands from the agent
CMD ["sleep", "infinity"]
