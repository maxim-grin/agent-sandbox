---
description: Install dependencies and build
model: openai/gpt-4o-2024-08-06
---
Discovery output:
!cat /workspace/.pipeline/discovery.json

Run the install_cmd, then the build_cmd from the discovery output above.
Write /workspace/.pipeline/build.json:
{"status": "success"|"failure", "exit_code": <n>, "logs": "<combined stdout and stderr>"}
