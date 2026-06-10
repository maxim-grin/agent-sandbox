# syntax=docker/dockerfile:1

# Stage 1: install global tools (cached layer, rebuilt only when Node version changes)
FROM node:20-alpine AS toolchain

RUN apk add --no-cache git curl

# Pre-install common TypeScript tooling so agent runs don't hit the registry
RUN npm install -g typescript ts-node ts-node-dev 2>/dev/null

# Stage 2: runtime image (no build artifacts, lean layer)
FROM node:20-alpine AS runtime

RUN apk add --no-cache git curl openssh

# Non-root user for all agent-driven commands (fixed UID/GID so the runner
# can chown the cloned workspace without needing sandboxuser to exist there).
RUN addgroup -S -g 1001 sandboxgroup \
    && adduser -S -u 1001 -G sandboxgroup -s /bin/sh sandboxuser \
    && passwd -d sandboxuser

# Copy globally installed tools from the toolchain stage
COPY --from=toolchain /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=toolchain /usr/local/bin/tsc          /usr/local/bin/tsc
COPY --from=toolchain /usr/local/bin/ts-node      /usr/local/bin/ts-node
COPY --from=toolchain /usr/local/bin/ts-node-dev  /usr/local/bin/ts-node-dev

# /workspace is mounted at runtime from the workspace volume (cloned by run_agent.sh)
RUN mkdir -p /workspace /sandbox/results/logs \
    && chown -R sandboxuser:sandboxgroup /workspace /sandbox

# SSH host keys stable across container restarts within a run
RUN ssh-keygen -A

RUN mkdir -p /home/sandboxuser/.ssh \
    && chmod 755 /home/sandboxuser/.ssh \
    && printf 'StrictModes no\nKexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256,diffie-hellman-group14-sha256\n' >> /etc/ssh/sshd_config

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /workspace

HEALTHCHECK --interval=5s --timeout=3s --retries=3 \
  CMD node --version

CMD ["/usr/local/bin/docker-entrypoint.sh"]
