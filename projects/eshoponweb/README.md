# eShopOnWeb Stack

Worker stack for [eShopOnWeb](https://github.com/NimblePros/eShopOnWeb) — a reference ASP.NET Core application demonstrating clean architecture with MVC and Blazor WebAssembly frontends.

## Stack composition

| Container | Image | Role |
|-----------|-------|------|
| `eshoponweb-worker` | `ai-sandbox-eshoponweb-worker` (.NET SDK 10, non-root) | Runs agent commands against the cloned workspace |

No SQL Server container is included. SQL Server has no ARM64 image and cannot run on Apple Silicon. The application is configured to use EF Core in-memory databases via the `UseOnlyInMemoryDatabase=true` environment variable, which is sufficient for build validation, test execution, and health-check probing.

## Job spec

```json
{
  "project_type": "eshoponweb",
  "repo_url": "https://github.com/NimblePros/eShopOnWeb",
  "commit": "main"
}
```

## Quickstart

```bash
cat > /tmp/eshoponweb-job.json <<'EOF'
{
  "project_type": "eshoponweb",
  "repo_url": "https://github.com/NimblePros/eShopOnWeb",
  "commit": "main"
}
EOF

./scripts/run_job.sh /tmp/eshoponweb-job.json
```

## Example agent session

The agent reads `eShopOnWeb.sln` and `src/Web/Web.csproj` inside `/workspace`, then drives the sandbox:

```
EXEC restore dotnet restore
EXIT_CODE restore 0
EXEC build dotnet build --no-restore --configuration Debug
EXIT_CODE build 0
EXEC test dotnet test tests/UnitTests --no-build
EXIT_CODE test 0
EXEC test-integration dotnet test tests/IntegrationTests --no-build
EXIT_CODE test-integration 0
EXEC start-server sh -c 'dotnet run --project src/Web --no-build --no-launch-profile &'
EXIT_CODE start-server 0
HEALTHCHECK http://<worker>:5000/api_health_check
HEALTHCHECK_STATUS 200
DONE
```

`examples/run_eshoponweb_example.sh` is a harness simulation that does exactly this. It is not required behaviour — a real AI agent would read the source files and infer these commands via LLM.

## In-memory database

The env var `UseOnlyInMemoryDatabase=true` (set in `docker-compose.yml`) is read by `src/Infrastructure/Dependencies.cs`:

```csharp
if (useOnlyInMemoryDatabase)
{
    services.AddDbContext<CatalogContext>(c =>
        c.UseInMemoryDatabase("Catalog"));
    services.AddDbContext<AppIdentityDbContext>(c =>
        c.UseInMemoryDatabase("Identity"));
}
```

Both database contexts use EF Core in-memory databases. Seed data loads on startup via `app.SeedDatabaseAsync()` in `Program.cs`.

## Health check endpoints

Program.cs registers two health check routes:

| Route | Tag | URL |
|-------|-----|-----|
| `home_page_health_check` | `homePageHealthCheck` | `http://<host>:5000/home_page_health_check` |
| `api_health_check` | `apiHealthCheck` | `http://<host>:5000/api_health_check` |

The example harness probes `/api_health_check`.

## HTTP vs HTTPS

`ASPNETCORE_URLS=http://0.0.0.0:5000` (set in `docker-compose.yml`) binds the server to HTTP only. The `UseHttpsRedirection()` middleware in ASP.NET Core is a no-op when no HTTPS port is configured, so HTTP requests are served directly without redirects.

## Resource limits

| Container | Memory | CPU |
|-----------|--------|-----|
| eshoponweb-worker | 2 GB | 2.0 |

**When limits are hit:**

- **Worker OOM** — Docker kills the container (exit 137). The supervisor writes `result.json` with `"status": "failure"`. Treat exit 137 as an OOM signal; increase `mem_limit` in `docker-compose.yml`.
- **CPU throttle** — Worker is slowed but not killed. Increase harness timeouts for restore/build steps.

## Build performance (cold start, warm images)

| Phase | Approximate time |
|-------|-----------------|
| Build worker image (first time) | ~2 min |
| Build worker image (cached) | <5s |
| Clone eShopOnWeb repo | ~15s |
| `dotnet restore` (cold NuGet cache) | ~2–3 min |
| `dotnet build` | ~1–2 min |
| `dotnet test tests/UnitTests` | ~30s |
| `dotnet test tests/IntegrationTests` | ~1 min |
| **Total (warm images, cold NuGet cache)** | **~8–10 min** |

### Improvement options

- Mount a persistent `nuget-cache` volume at `/home/sandboxuser/.nuget/packages` to avoid re-downloading packages across runs.
- Pre-populate the NuGet cache in the worker image using a dummy project that restores all common eShopOnWeb dependencies.
- Pre-clone the repo and run `dotnet restore` in the image build phase (trades image size for faster job startup).
