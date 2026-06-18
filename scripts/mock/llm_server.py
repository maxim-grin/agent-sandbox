#!/usr/bin/env python3
"""OpenAI Responses API mock with SSE streaming (required by opencode ≥1.17).
Handles POST /v1/responses with stream:true.

MOCK_WORKSPACE=true (default): pre-canned single-turn fixture path.
MOCK_WORKSPACE=false: stateful multi-turn step machines with real bash commands.
"""
import base64
import json
import http.server
import os
import re
import time
import uuid

RESPONSES_DIR = os.path.join(os.path.dirname(__file__), "responses")
PIPELINE_STAGES = ("discovery", "build", "tests", "run")

MOCK_WORKSPACE = os.environ.get("MOCK_WORKSPACE", "true").lower() == "true"


# ---------------------------------------------------------------------------
# Session helpers
# ---------------------------------------------------------------------------

def _new_resp_id():
    return f"resp_mock_{uuid.uuid4().hex[:12]}"


def _collect_stage_tool_outputs(items, stage):
    """Collect function_call_output values that belong to the current stage.

    Find the last user/system message containing .pipeline/<stage>.json
    (the stage's instruction) and return only tool outputs after that point.
    Previous-stage tool outputs are excluded.
    """
    stage_pattern = f".pipeline/{stage}.json"
    last_instruction_idx = -1
    for idx, item in enumerate(items):
        if not isinstance(item, dict):
            continue
        content = item.get("content", "")
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            text = " ".join(
                part.get("text", "") for part in content
                if isinstance(part, dict)
            )
        else:
            continue
        if stage_pattern in text:
            last_instruction_idx = idx

    start = last_instruction_idx + 1 if last_instruction_idx >= 0 else 0
    return [
        i.get("output", "")
        for i in items[start:]
        if isinstance(i, dict) and i.get("type") == "function_call_output"
    ]


def _parse_cmds_from_instructions(body):
    """Find JSON object containing install_cmd embedded in the instructions field."""
    instructions = body.get("instructions", "")
    if isinstance(instructions, str):
        text = instructions
    elif isinstance(instructions, dict):
        text = str(instructions.get("content", ""))
    else:
        text = ""
    for item in body.get("input", []):
        if not isinstance(item, dict):
            continue
        content = item.get("content", "")
        if isinstance(content, str):
            text += " " + content
        elif isinstance(content, list):
            for part in content:
                if isinstance(part, dict):
                    text += " " + part.get("text", "")
    match = re.search(r'\{[^{}]*"install_cmd"[^{}]*\}', text, re.DOTALL)
    if match:
        try:
            return json.loads(match.group(0))
        except Exception:
            pass
    return {}


# ---------------------------------------------------------------------------
# Fixture / canned-response helpers (MOCK_WORKSPACE=true path)
# ---------------------------------------------------------------------------

def _load_fixture(stage):
    path = os.path.join(RESPONSES_DIR, f"{stage}.json")
    try:
        with open(path) as f:
            return f.read().strip()
    except FileNotFoundError:
        return None


def _make_write_cmd(stage):
    content = _load_fixture(stage)
    if content is None:
        content = json.dumps({"status": "success"})
    b64 = base64.b64encode(content.encode()).decode()
    return (
        f"mkdir -p /workspace/.pipeline && "
        f"printf '%s' '{b64}' | base64 -d > /workspace/.pipeline/{stage}.json && "
        f"echo done"
    )


# ---------------------------------------------------------------------------
# Stage detection helpers
# ---------------------------------------------------------------------------

def _extract_stage(body):
    instructions = body.get("instructions", "")
    if isinstance(instructions, str):
        all_text = instructions + " "
    elif isinstance(instructions, dict):
        all_text = str(instructions.get("content", "")) + " "
    else:
        all_text = ""
    for item in body.get("input", []):
        if not isinstance(item, dict):
            continue
        content = item.get("content", "")
        if isinstance(content, str):
            all_text += content + " "
        elif isinstance(content, list):
            for part in content:
                if isinstance(part, dict) and part.get("type") in ("input_text", "text"):
                    all_text += part.get("text", "") + " "
    matches = re.findall(r'\.pipeline/(discovery|build|tests|run)\.json', all_text)
    return matches[-1] if matches else None


def _has_tool_result(items):
    return any(
        isinstance(i, dict) and i.get("type") == "function_call_output"
        for i in items
    )


def _last_tool_call_stage(items):
    last_args = None
    for item in items:
        if isinstance(item, dict) and item.get("type") == "function_call":
            last_args = item.get("arguments", "")
    if not last_args:
        return None
    matches = re.findall(r'\.pipeline/(discovery|build|tests|run)\.json', last_args)
    return matches[-1] if matches else None


def _bash_tool_name(tools):
    for t in tools:
        if isinstance(t, dict):
            name = t.get("name", t.get("function", {}).get("name", ""))
            if "bash" in name.lower():
                return name
    return "bash"


# ---------------------------------------------------------------------------
# SSE event builders
# ---------------------------------------------------------------------------

def _make_tool_call_events(tool_name, arguments_str, resp_id):
    fc_id = "fc_mock1"
    call_id = "call_mock1"
    ts = int(time.time())
    return [
        {"type": "response.created", "response": {
            "id": resp_id, "object": "response", "created_at": ts,
            "model": "gpt-4o-2024-08-06", "status": "in_progress",
            "output": [], "usage": None,
        }},
        {"type": "response.in_progress", "response": {
            "id": resp_id, "status": "in_progress",
        }},
        {"type": "response.output_item.added", "output_index": 0, "item": {
            "type": "function_call", "id": fc_id, "call_id": call_id,
            "name": tool_name, "arguments": "", "status": "in_progress",
        }},
        {"type": "response.function_call_arguments.delta",
            "item_id": fc_id, "output_index": 0, "call_id": call_id,
            "delta": arguments_str},
        {"type": "response.function_call_arguments.done",
            "item_id": fc_id, "output_index": 0, "call_id": call_id,
            "arguments": arguments_str},
        {"type": "response.output_item.done", "output_index": 0, "item": {
            "type": "function_call", "id": fc_id, "call_id": call_id,
            "name": tool_name, "arguments": arguments_str, "status": "completed",
        }},
        {"type": "response.completed", "response": {
            "id": resp_id, "object": "response", "created_at": ts,
            "model": "gpt-4o-2024-08-06", "status": "completed",
            "output": [{"type": "function_call", "id": fc_id, "call_id": call_id,
                        "name": tool_name, "arguments": arguments_str, "status": "completed"}],
            "usage": {"input_tokens": 10, "input_tokens_details": {"cached_tokens": 0},
                      "output_tokens": 20, "output_tokens_details": {"reasoning_tokens": 0},
                      "total_tokens": 30},
        }},
    ]


def _make_text_events(text, resp_id):
    msg_id = "msg_mock1"
    ts = int(time.time())
    return [
        {"type": "response.created", "response": {
            "id": resp_id, "object": "response", "created_at": ts,
            "model": "gpt-4o-2024-08-06", "status": "in_progress", "output": [],
        }},
        {"type": "response.in_progress", "response": {
            "id": resp_id, "status": "in_progress",
        }},
        {"type": "response.output_item.added", "output_index": 0, "item": {
            "type": "message", "id": msg_id, "role": "assistant",
            "content": [], "status": "in_progress",
        }},
        {"type": "response.content_part.added",
            "item_id": msg_id, "output_index": 0, "content_index": 0,
            "part": {"type": "output_text", "text": ""}},
        {"type": "response.output_text.delta",
            "item_id": msg_id, "output_index": 0, "content_index": 0,
            "delta": text},
        {"type": "response.output_text.done",
            "item_id": msg_id, "output_index": 0, "content_index": 0,
            "text": text},
        {"type": "response.content_part.done",
            "item_id": msg_id, "output_index": 0, "content_index": 0,
            "part": {"type": "output_text", "text": text}},
        {"type": "response.output_item.done", "output_index": 0, "item": {
            "type": "message", "id": msg_id, "role": "assistant",
            "content": [{"type": "output_text", "text": text}], "status": "completed",
        }},
        {"type": "response.completed", "response": {
            "id": resp_id, "object": "response", "created_at": ts,
            "model": "gpt-4o-2024-08-06", "status": "completed",
            "output": [{"type": "message", "id": msg_id, "role": "assistant",
                        "content": [{"type": "output_text", "text": text}], "status": "completed"}],
            "usage": {"input_tokens": 30, "input_tokens_details": {"cached_tokens": 0},
                      "output_tokens": 5, "output_tokens_details": {"reasoning_tokens": 0},
                      "total_tokens": 35},
        }},
    ]


# ---------------------------------------------------------------------------
# Stateful stage handlers (MOCK_WORKSPACE=false path)
# ---------------------------------------------------------------------------

def _parse_vitest(output):
    passed_m = re.search(r'Tests\s+(\d+) passed', output)
    failed_m = re.search(r'(\d+) failed', output)
    passed = int(passed_m.group(1)) if passed_m else 0
    failed = int(failed_m.group(1)) if failed_m else 0
    return passed, failed


def _write_json_cmd(stage, data):
    b64 = base64.b64encode(json.dumps(data).encode()).decode()
    return (
        f"mkdir -p /workspace/.pipeline && "
        f"printf '%s' '{b64}' | base64 -d > /workspace/.pipeline/{stage}.json && "
        f"echo done"
    )


def _handle_discovery(state, body, tool_name, resp_id):
    step = state["step"]
    if step == 0:
        cmd = "cat /workspace/package.json 2>&1"
        return _make_tool_call_events(tool_name, json.dumps({"command": cmd, "description": "Read package.json"}), resp_id)
    if step == 1:
        raw = state["logs"][0] if state["logs"] else "{}"
        try:
            pkg = json.loads(raw)
        except Exception:
            pkg = {}
        discovery = {
            "install_cmd": "npm ci",
            "build_cmd": "npm run build",
            "test_cmd": "npm test",
            "start_cmd": "npm start",
            "health_url": "http://localhost:3000/health",
            "port": 3000,
        }
        cmd = _write_json_cmd("discovery", discovery)
        return _make_tool_call_events(tool_name, json.dumps({"command": cmd, "description": "Write discovery.json"}), resp_id)
    return _make_text_events("Discovery complete.", resp_id)


def _handle_build(state, body, tool_name, resp_id):
    step = state["step"]
    cmds = _parse_cmds_from_instructions(body)
    if step == 0:
        install_cmd = cmds.get("install_cmd", "npm ci")
        build_cmd = cmds.get("build_cmd", "npm run build")
        # use workspace npm cache (home tmpfs is only 200MB, fills up quickly)
        # retry install once to handle transient ETXTBSY race condition in npm postinstall scripts
        cmd = (
            f"cd /workspace && npm_config_cache=/workspace/.npm-cache {install_cmd} 2>&1; RC=$?; "
            f"if [ $RC -ne 0 ]; then sleep 1; npm_config_cache=/workspace/.npm-cache {install_cmd} 2>&1; RC=$?; fi; "
            f"if [ $RC -eq 0 ]; then {build_cmd} 2>&1; RC=$?; fi; "
            f"echo EXIT:$RC"
        )
        return _make_tool_call_events(tool_name, json.dumps({"command": cmd, "description": "Install deps and build"}), resp_id)
    if step == 1:
        build_log = state["logs"][-1] if state["logs"] else ""
        match = re.search(r'EXIT:(\d+)', build_log)
        exit_code = int(match.group(1)) if match else 0
        result = {
            "status": "success" if exit_code == 0 else "failure",
            "exit_code": exit_code,
            "logs": "\n".join(state["logs"]),
        }
        cmd = _write_json_cmd("build", result)
        return _make_tool_call_events(tool_name, json.dumps({"command": cmd, "description": "Write build.json"}), resp_id)
    return _make_text_events("Build complete.", resp_id)


def _handle_tests(state, body, tool_name, resp_id):
    step = state["step"]
    cmds = _parse_cmds_from_instructions(body)
    if step == 0:
        test_cmd = cmds.get("test_cmd", "npm test")
        cmd = f"cd /workspace && {test_cmd} 2>&1; echo EXIT:$?"
        return _make_tool_call_events(tool_name, json.dumps({"command": cmd, "description": "Run tests"}), resp_id)
    if step == 1:
        test_log = state["logs"][-1] if state["logs"] else ""
        passed, failed = _parse_vitest(test_log)
        result = {
            "status": "success" if failed == 0 else "failure",
            "passed": passed,
            "failed": failed,
            "logs": "\n".join(state["logs"]),
        }
        cmd = _write_json_cmd("tests", result)
        return _make_tool_call_events(tool_name, json.dumps({"command": cmd, "description": "Write tests.json"}), resp_id)
    return _make_text_events("Tests complete.", resp_id)


def _handle_run(state, body, tool_name, resp_id):
    step = state["step"]
    cmds = _parse_cmds_from_instructions(body)
    if step == 0:
        start_cmd = cmds.get("start_cmd", "npm start")
        # double-fork: subshell starts server in background then exits;
        # npm start is reparented to PID 1, not bash — prevents bash from waiting for it
        # use /workspace/srv.log — /tmp is an external_directory and triggers opencode permission prompt
        cmd = f"cd /workspace && (setsid {start_cmd} >> /workspace/srv.log 2>&1 &) && echo started"
        return _make_tool_call_events(tool_name, json.dumps({"command": cmd, "description": "Start server"}), resp_id)
    if step == 1:
        cmd = 'sleep 3 && curl -s -o /dev/null -w "%{http_code}" --max-time 5 --connect-timeout 3 http://localhost:3000/health 2>/dev/null; echo; cat /workspace/srv.log 2>/dev/null'
        return _make_tool_call_events(tool_name, json.dumps({"command": cmd, "description": "Health check"}), resp_id)
    if step == 2:
        run_log = state["logs"][-1] if state["logs"] else ""
        lines = run_log.strip().split("\n")
        try:
            response_code = int(lines[0].strip())
        except (ValueError, IndexError):
            response_code = 0
        result = {
            "status": "success" if response_code == 200 else "failure",
            "response_code": response_code,
            "logs": "\n".join(state["logs"]),
        }
        cmd = _write_json_cmd("run", result)
        return _make_tool_call_events(tool_name, json.dumps({"command": cmd, "description": "Write run.json"}), resp_id)
    return _make_text_events("Started.", resp_id)


_STAGE_HANDLERS = {
    "discovery": _handle_discovery,
    "build": _handle_build,
    "tests": _handle_tests,
    "run": _handle_run,
}


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[mock-llm] {fmt % args}", flush=True)

    def do_GET(self):
        if self.path in ("/health", "/v1/health"):
            self._json(200, {"ok": True})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length)) if length else {}

        if self.path != "/v1/responses":
            self._json(404, {"error": f"unknown path: {self.path}"})
            return

        print(f"[mock-llm] keys={list(body.keys())}", flush=True)

        tools = body.get("tools", [])

        if not tools:
            self._sse(_make_text_events("Mock session title", _new_resp_id()))
            return

        stage = _extract_stage(body)
        print(
            f"[mock-llm] /v1/responses tools={len(tools)} stage={stage} "
            f"MOCK_WORKSPACE={MOCK_WORKSPACE}",
            flush=True,
        )

        # --- Stateful multi-turn path (real workspace) ---
        # opencode sends full conversation history in input[], not previous_response_id.
        # Step is derived from tool outputs belonging to the current stage only.
        if not MOCK_WORKSPACE and stage in PIPELINE_STAGES:
            items = body.get("input", [])
            logs = _collect_stage_tool_outputs(items, stage)
            state = {"stage": stage, "step": len(logs), "logs": logs}

            resp_id = _new_resp_id()
            tool_name = _bash_tool_name(tools)
            handler = _STAGE_HANDLERS[stage]
            print(f"[mock-llm] stateful stage={stage} step={state['step']}", flush=True)
            events = handler(state, body, tool_name, resp_id)

            self._sse(events)
            return

        # --- Pre-canned fixture path (MOCK_WORKSPACE=true or unknown stage) ---
        items = body.get("input", [])
        has_tool_result = _has_tool_result(items)
        last_tool_stage = _last_tool_call_stage(items)
        current_stage_done = has_tool_result and last_tool_stage == stage

        if current_stage_done:
            self._sse(_make_text_events(f"Done. {stage or 'file'} written.", _new_resp_id()))
            return

        tool_name = _bash_tool_name(tools)
        if stage in PIPELINE_STAGES:
            write_cmd = _make_write_cmd(stage)
            arguments = json.dumps({"command": write_cmd, "description": f"Write {stage}.json"})
            self._sse(_make_tool_call_events(tool_name, arguments, _new_resp_id()))
        else:
            arguments = json.dumps({"command": "echo 'done'", "description": "Generic fallback"})
            self._sse(_make_tool_call_events(tool_name, arguments, _new_resp_id()))

    def _sse(self, events):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        for event in events:
            line = f"data: {json.dumps(event)}\n\n"
            self.wfile.write(line.encode())
            self.wfile.flush()

    def _json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    print(f"Mock LLM server on :8080 (SSE streaming, MOCK_WORKSPACE={MOCK_WORKSPACE})", flush=True)
    server = http.server.HTTPServer(("0.0.0.0", 8080), Handler)
    server.serve_forever()
