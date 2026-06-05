FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    git \
    jq \
    curl \
    docker-cli \
    docker-compose

COPY entrypoint.sh /supervisor/entrypoint.sh
COPY lib/           /supervisor/lib/

RUN chmod +x /supervisor/entrypoint.sh /supervisor/lib/*.sh

VOLUME ["/sandbox/workspace", "/sandbox/results"]

ENTRYPOINT ["/supervisor/entrypoint.sh"]
