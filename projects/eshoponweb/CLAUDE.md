# eShopOnWeb — Agent Guide

.NET 10 / C# / ASP.NET Core MVC + Blazor WebAssembly. No database container — uses EF Core in-memory databases.

## Runtime environment

| What | Value |
|------|-------|
| Runtime | .NET SDK 10 (multi-arch, Apple Silicon compatible) |
| Database | None — EF Core in-memory via `UseOnlyInMemoryDatabase=true` |
| Workspace | `/workspace` |
| Results / logs | `/sandbox/results/logs/` |

Key env vars pre-set in the worker container:

| Var | Value |
|-----|-------|
| `UseOnlyInMemoryDatabase` | `true` |
| `ASPNETCORE_URLS` | `http://0.0.0.0:5000` |
| `ASPNETCORE_ENVIRONMENT` | `Development` |
| `baseUrls__apiBase` | `http://localhost:5099/api/` |
| `DOTNET_CLI_TELEMETRY_OPTOUT` | `1` |

## Standard workflow

```
EXEC restore          dotnet restore
EXEC build            dotnet build --no-restore --configuration Debug
EXEC test             dotnet test tests/UnitTests --no-build
EXEC test-integration dotnet test tests/IntegrationTests --no-build
EXEC start-server     sh -c 'dotnet run --project src/Web --no-build --no-launch-profile &'
HEALTHCHECK           http://<worker-container>:5000/api_health_check
DONE
```

Labels `build` and `test` are special — supervisor records their exit codes in `result.json`.

### Why each step matters

- **`--no-launch-profile`**: without it, `dotnet run` reads `src/Web/Properties/launchSettings.json` and binds to HTTPS (`https://localhost:5001`), overriding `ASPNETCORE_URLS`. This flag ensures the container env vars are respected.
- **`test-integration`**: integration tests already reference `Microsoft.EntityFrameworkCore.InMemory` — no extra config needed.
- **Skip `tests/FunctionalTests`**: requires Playwright / live browser context, not suitable for headless execution.
- **`baseUrls__apiBase`**: required so `ApiHealthCheck` can reach the `PublicApi` project on port 5099 over plain HTTP instead of the default HTTPS dev cert URL.

## Health endpoints

| Route | Use |
|-------|-----|
| `http://<worker>:5000/api_health_check` | Primary probe — checks API layer |
| `http://<worker>:5000/home_page_health_check` | Secondary probe — checks MVC layer |

HTTP only — no HTTPS certificate is configured. `UseHttpsRedirection()` is a no-op when no HTTPS port is bound.

## In-memory database notes

`src/Infrastructure/Dependencies.cs` checks `UseOnlyInMemoryDatabase` and switches both `CatalogContext` and `AppIdentityDbContext` to EF Core in-memory databases. `CatalogContextSeed.SeedAsync()` skips the CSV-backed catalog seed (guarded by `IsSqlServer()`), but identity/admin seed data loads normally on startup via `app.SeedDatabaseAsync()`.

## Key files to inspect

| File | Purpose |
|------|---------|
| `eShopOnWeb.sln` | Solution structure — lists all projects |
| `global.json` | SDK version pin (`10.0.x`, `rollForward: latestFeature`) |
| `src/Web/Web.csproj` | Main web app entry point |
| `src/Infrastructure/Dependencies.cs` | In-memory DB wiring |
| `src/Web/Program.cs` | Health check route registration, startup seed |

## Failure signals

| Exit code | Meaning |
|-----------|---------|
| 137 | Worker OOM — needs more memory |
| non-zero `test` | Unit tests failed — read `logs/test.log` |
| non-zero `test-integration` | Integration tests failed — read `logs/test-integration.log` |
| healthcheck ≠ 200 | Server didn't start or failed to seed — read `logs/start-server.log` |
