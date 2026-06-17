---
description: Start server and verify health
model: openai/gpt-4o-2024-08-06
subtask: true
---
Discovery output:
!cat /workspace/.pipeline/discovery.json

Run the start_cmd from the discovery output in the background. Poll the health_url until the server responds or 30 seconds elapse.
Write /workspace/.pipeline/run.json:
{"status": "success"|"failure", "response_code": <http_status_code>, "logs": "<combined stdout and stderr>"}
