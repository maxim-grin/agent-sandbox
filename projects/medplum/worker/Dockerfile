# syntax=docker/dockerfile:1

# Stage 1: install global tools (cached layer, rebuilt only when Node version changes)
FROM node:20-alpine AS toolchain

RUN apk add --no-cache git curl

# Install pnpm (Medplum's package manager)
RUN npm install -g pnpm

# Stage 2: runtime image (lean, no baked-in source)
FROM node:20-alpine AS runtime

RUN apk add --no-cache git curl

# Non-root user for all agent-driven commands (fixed UID/GID so the supervisor
# can chown the cloned workspace without needing sandboxuser to exist there).
RUN addgroup -S -g 1001 sandboxgroup && adduser -S -u 1001 -G sandboxgroup sandboxuser

# Copy globally installed pnpm from the toolchain stage
COPY --from=toolchain /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=toolchain /usr/local/bin/pnpm         /usr/local/bin/pnpm

# Point pnpm's data dirs at /tmp so the system user (no home dir) can write there.
# /tmp is world-writable in containers; hardlinks within the overlay fs still work.
ENV PNPM_HOME="/tmp/pnpm-home"
ENV PNPM_STORE_DIR="/tmp/pnpm-store"
ENV PATH="$PNPM_HOME:$PATH"

# /workspace is mounted at runtime from the workspace volume (cloned by supervisor)
RUN mkdir -p /workspace /sandbox/results/logs \
    && chown -R sandboxuser:sandboxgroup /workspace /sandbox

WORKDIR /workspace

USER sandboxuser

HEALTHCHECK --interval=5s --timeout=3s --retries=3 \
  CMD node --version

# Keeps the container alive for docker exec commands from the agent
CMD ["sleep", "infinity"]
