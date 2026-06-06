# syntax=docker/dockerfile:1
#
# eShopOnWeb worker image — .NET SDK 10 (multi-arch, Apple Silicon compatible).
# No SQL Server dependency: the application is configured to use in-memory
# databases via the UseOnlyInMemoryDatabase=true environment variable.

FROM mcr.microsoft.com/dotnet/sdk:10.0

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl \
    && rm -rf /var/lib/apt/lists/*

# Non-root user for all agent-driven commands (fixed UID/GID so the supervisor
# can chown the cloned workspace without needing sandboxuser to exist there).
RUN groupadd -g 1001 sandboxgroup && useradd -u 1001 -g sandboxgroup -m sandboxuser

# /workspace is mounted at runtime from the workspace volume (cloned by supervisor)
RUN mkdir -p /workspace /sandbox/results/logs \
    && chown -R sandboxuser:sandboxgroup /workspace /sandbox

# Pre-warm the NuGet CLI so first-run initialisation does not add latency
# to the agent's restore step.
RUN dotnet --version

WORKDIR /workspace

USER sandboxuser

HEALTHCHECK --interval=5s --timeout=5s --retries=3 \
  CMD dotnet --version

# Keeps the container alive for docker exec commands from the agent
CMD ["sleep", "infinity"]
