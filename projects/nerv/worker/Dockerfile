# syntax=docker/dockerfile:1

FROM node:20-alpine@sha256:fb4cd12c85ee03686f6af5362a0b0d56d50c58a04632e6c0fb8363f609372293 AS toolchain

RUN apk add --no-cache git curl
RUN npm install -g typescript ts-node ts-node-dev 2>/dev/null

FROM node:20-alpine@sha256:fb4cd12c85ee03686f6af5362a0b0d56d50c58a04632e6c0fb8363f609372293 AS runtime

RUN apk add --no-cache git curl wget jq bash

# opencode binary: install script writes to /root/.opencode/bin (root-only dir).
# Copy binary to /usr/local/bin so non-root user can execute it.
ENV SHELL=/bin/bash
RUN curl -fsSL https://opencode.ai/install | bash && \
    cp /root/.opencode/bin/opencode /usr/local/bin/opencode && \
    chmod 755 /usr/local/bin/opencode

# opencode plugin installed globally; config written by entrypoint at runtime
RUN npm install -g @anthonyfangqing/opencode-special-edition

RUN addgroup -S -g 1001 ocgroup && adduser -S -u 1001 -G ocgroup -s /bin/sh ocuser

RUN mkdir -p /workspace /workspace/.pipeline \
    && chown -R ocuser:ocgroup /workspace
RUN mkdir -p /home/ocuser/.opencode /home/ocuser/.local /root/.local \
    && chown -R ocuser:ocgroup /home/ocuser

COPY --from=toolchain /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=toolchain /usr/local/bin/tsc          /usr/local/bin/tsc
COPY --from=toolchain /usr/local/bin/ts-node      /usr/local/bin/ts-node
COPY --from=toolchain /usr/local/bin/ts-node-dev  /usr/local/bin/ts-node-dev

COPY opencode.json /etc/opencode/opencode.json
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER ocuser
WORKDIR /workspace

HEALTHCHECK --interval=5s --timeout=5s --retries=6 \
  CMD curl -sf -u opencode:${OPENCODE_SERVER_PASSWORD:-} http://${OPENCODE_HOST:-127.0.0.1}:${OPENCODE_PORT:-4096}/global/health > /dev/null

CMD ["/usr/local/bin/docker-entrypoint.sh"]
