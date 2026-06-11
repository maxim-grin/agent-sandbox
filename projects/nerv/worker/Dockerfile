# syntax=docker/dockerfile:1

FROM node:20-alpine AS toolchain

RUN apk add --no-cache git curl
RUN npm install -g typescript ts-node ts-node-dev 2>/dev/null

FROM node:20-alpine AS runtime

RUN apk add --no-cache git curl wget jq bash

# opencode binary — install script writes to ~/.local/bin
ENV PATH="/root/.opencode/bin:${PATH}"
ENV SHELL=/bin/bash
RUN curl -fsSL https://opencode.ai/install | bash

COPY --from=toolchain /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=toolchain /usr/local/bin/tsc          /usr/local/bin/tsc
COPY --from=toolchain /usr/local/bin/ts-node      /usr/local/bin/ts-node
COPY --from=toolchain /usr/local/bin/ts-node-dev  /usr/local/bin/ts-node-dev

RUN mkdir -p /workspace /workspace/.pipeline \
    && chmod -R 777 /workspace

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /workspace

HEALTHCHECK --interval=5s --timeout=5s --retries=6 \
  CMD wget -q -O /dev/null http://localhost:4096/global/health

CMD ["/usr/local/bin/docker-entrypoint.sh"]
