# eShopOnWeb Stack

[eShopOnWeb](https://github.com/NimblePros/eShopOnWeb) is a reference ASP.NET Core application demonstrating clean architecture with MVC and Blazor WebAssembly frontends, maintained by NimblePros.

## Stack

| Container | Image | Role |
|-----------|-------|------|
| `eshoponweb-worker` | `ai-sandbox-eshoponweb-worker` (.NET SDK 10) | Runs agent commands |

No SQL Server container — SQL Server has no ARM64 image and cannot run on Apple Silicon. The application supports an in-memory database mode (`UseOnlyInMemoryDatabase=true`) which is sufficient for build validation, test execution, and health-check probing.

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

## Resource limits

| Container | Memory | CPU |
|-----------|--------|-----|
| eshoponweb-worker | 2 GB | 2.0 |

## Build performance (warm images, cold NuGet cache)

| Phase | Time |
|-------|------|
| Build worker image (first time) | ~2 min |
| Build worker image (cached) | <5s |
| Clone repo | ~15s |
| `dotnet restore` | ~2–3 min |
| `dotnet build` | ~1–2 min |
| Unit + integration tests | ~90s |
| **Total** | **~8–10 min** |

### Improvement options

- Mount a persistent volume at `/home/sandboxuser/.nuget/packages` to cache NuGet packages across runs.
- Pre-populate the NuGet cache in the worker image using a dummy project.
- Pre-clone and run `dotnet restore` in the image build phase (trades image size for faster startup).
