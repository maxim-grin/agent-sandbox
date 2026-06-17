---
description: Discover build/test/run commands
model: openai/gpt-4o-2024-08-06
subtask: true
---
Read /workspace/package.json (or equivalent manifest: Cargo.toml, pyproject.toml, go.mod, pom.xml).
Determine install, build, test, and start commands. Identify the HTTP health check URL and port.
Create /workspace/.pipeline/ directory if it does not exist.
Write /workspace/.pipeline/discovery.json:
{"install_cmd": "<cmd>", "build_cmd": "<cmd>", "test_cmd": "<cmd>", "start_cmd": "<cmd>", "health_url": "<url>", "port": <port>}
