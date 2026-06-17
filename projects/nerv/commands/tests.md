---
description: Run test suite
model: openai/gpt-4o-2024-08-06
---
Discovery output:
!cat /workspace/.pipeline/discovery.json

Build output:
!cat /workspace/.pipeline/build.json

Run the test_cmd from the discovery output. Parse pass/fail counts from output.
Write /workspace/.pipeline/tests.json:
{"status": "success"|"failure", "passed": <n>, "failed": <n>, "logs": "<combined stdout and stderr>"}
