#!/usr/bin/env python3
"""OpenAI Responses API mock with SSE streaming (required by opencode ≥1.17).
Handles POST /v1/responses with stream:true.
"""
import json
import http.server
import time

WRITE_CMD = (
    "printf '%s' "
    "'{\"status\":\"success\",\"message\":\"hello from opencode\"}'"
    " > /workspace/result.json && echo done"
)


def _has_tool_result(items):
    return any(
        isinstance(i, dict) and i.get("type") == "function_call_output"
        for i in items
    )


def _bash_tool_name(tools):
    for t in tools:
        if isinstance(t, dict):
            name = t.get("name", t.get("function", {}).get("name", ""))
            if "bash" in name.lower():
                return name
    return "bash"


def _make_tool_call_events(tool_name, arguments_str):
    resp_id = "resp_mock1"
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


def _make_text_events(text):
    resp_id = "resp_mock2"
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

        items = body.get("input", [])
        tools = body.get("tools", [])
        has_tool_result = _has_tool_result(items)
        print(f"[mock-llm] /v1/responses tools={len(tools)} has_tool_result={has_tool_result}", flush=True)

        if not tools:
            # Title generation or other system call — return plain text
            self._sse(_make_text_events("Mock session title"))
            return

        if has_tool_result:
            self._sse(_make_text_events("Done. File written."))
        else:
            tool_name = _bash_tool_name(tools)
            arguments = json.dumps({"command": WRITE_CMD, "description": "Write result.json"})
            self._sse(_make_tool_call_events(tool_name, arguments))

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
    server = http.server.HTTPServer(("0.0.0.0", 8080), Handler)
    print("Mock LLM server on :8080 (SSE streaming)", flush=True)
    server.serve_forever()
