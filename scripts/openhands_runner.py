#!/usr/bin/env python3
"""OpenHands SDK runner — executes agent via SSHRuntime, augments result.json with token/cost."""
import asyncio
import json
import os
import sys
from pathlib import Path

RESULTS_PATH = Path("/sandbox/results/result.json")


class SSHRuntime:
    """Thin runtime: executes agent actions over SSH into the worker container."""

    def __init__(self, ssh_host: str, ssh_user: str, ssh_key_path: str):
        import paramiko
        self._client = paramiko.SSHClient()
        self._client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        self._client.connect(ssh_host, username=ssh_user, key_filename=ssh_key_path)
        self._sftp = self._client.open_sftp()

    async def run(self, action):
        from openhands.events.action import BashAction, FileReadAction, FileWriteAction
        from openhands.events.observation import (
            BashObservation,
            FileReadObservation,
            FileWriteObservation,
        )

        if isinstance(action, BashAction):
            _, stdout, stderr = self._client.exec_command(
                action.command, get_pty=True, timeout=300
            )
            output = stdout.read().decode() + stderr.read().decode()
            return BashObservation(content=output)

        if isinstance(action, FileReadAction):
            with self._sftp.open(action.path) as f:
                return FileReadObservation(content=f.read().decode(), path=action.path)

        if isinstance(action, FileWriteAction):
            with self._sftp.open(action.path, "w") as f:
                f.write(action.content)
            return FileWriteObservation(content="", path=action.path)

        raise NotImplementedError(f"Unhandled action: {type(action)}")

    async def close(self):
        self._sftp.close()
        self._client.close()


async def run_agent(task: str) -> dict:
    from openhands.core.config import AppConfig, LLMConfig
    from openhands.core.main import run_controller

    secret_file = Path("/run/secrets/groq_api_key")
    if secret_file.exists():
        api_key = secret_file.read_text().strip()
    else:
        api_key = os.environ.get("LLM_API_KEY") or os.environ.get("GROQ_API_KEY") or ""

    llm_config = LLMConfig(
        model=os.environ["LLM_MODEL"],
        api_key=api_key,
        base_url=os.environ.get("LLM_BASE_URL") or None,
    )

    config = AppConfig(
        workspace_base="/workspace",
        workspace_mount_path="/workspace",
        run_as_openhands=False,
        llm=llm_config,
    )

    ssh_host = os.environ.get("SSH_HOST", "worker")
    ssh_user = os.environ.get("SSH_USER", "sandboxuser")
    ssh_key = os.environ.get("SSH_KEY", "/run/secrets/ssh_key")

    runtime = SSHRuntime(ssh_host, ssh_user, ssh_key)

    try:
        state = await run_controller(
            config=config,
            task_str=task,
            runtime=runtime,
            headless_mode=True,
        )
    finally:
        await runtime.close()

    session_tokens = {}
    session_cost = 0.0

    if state and hasattr(state, "metrics") and state.metrics:
        m = state.metrics
        session_tokens = {
            "prompt_tokens": int(getattr(m, "prompt_tokens", 0)),
            "completion_tokens": int(getattr(m, "completion_tokens", 0)),
            "cache_read_tokens": int(getattr(m, "cache_read_tokens", 0)),
            "cache_write_tokens": int(getattr(m, "cache_write_tokens", 0)),
        }
        session_cost = float(getattr(m, "accumulated_cost", 0.0))

    return {"session_tokens": session_tokens, "session_cost": session_cost}


def main():
    task = os.environ.get("TASK", "").strip()
    if not task:
        print("[runner] ERROR: TASK env var not set", file=sys.stderr)
        sys.exit(1)

    print(f"[runner] Task length: {len(task)} chars", flush=True)

    token_info: dict = {"session_tokens": {}, "session_cost": 0.0}
    try:
        token_info = asyncio.run(run_agent(task))
        print(f"[runner] Agent done. Cost: ${token_info['session_cost']:.4f}", flush=True)
    except Exception as exc:
        import traceback
        print(f"[runner] Agent error: {exc}", file=sys.stderr)
        traceback.print_exc()

    if RESULTS_PATH.exists():
        try:
            data = json.loads(RESULTS_PATH.read_text())
            print(f"[runner] result.json status: {data.get('status')}", flush=True)
        except json.JSONDecodeError as exc:
            print(f"[runner] result.json parse error: {exc}", file=sys.stderr)
            data = {"status": "failure", "errors": [f"result.json parse error: {exc}"]}
    else:
        print(f"[runner] WARNING: no result.json at {RESULTS_PATH}", file=sys.stderr)
        data = {"status": "failure", "errors": ["agent did not write result.json"]}

    data.update(token_info)
    RESULTS_PATH.parent.mkdir(parents=True, exist_ok=True)
    RESULTS_PATH.write_text(json.dumps(data, indent=2))
    print(f"[runner] Augmented result written: {RESULTS_PATH}", flush=True)


if __name__ == "__main__":
    main()
