#!/usr/bin/env python3
"""OpenHands SDK runner — executes agent via SSHRuntime, augments result.json with token/cost."""
import asyncio
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

RESULTS_PATH = Path("/sandbox/results/result.json")


def _make_ssh_runtime_class():
    """Build SSHRuntime as a proper Runtime subclass at call time."""
    from openhands.runtime.base import Runtime
    from openhands.events.observation.commands import CmdOutputObservation
    from openhands.events.observation.error import ErrorObservation
    from openhands.events.observation.files import (
        FileReadObservation,
        FileWriteObservation,
        FileEditObservation,
    )

    class SSHRuntime(Runtime):
        def __init__(
            self,
            config,
            event_stream,
            llm_registry,
            sid="default",
            plugins=None,
            env_vars=None,
            status_callback=None,
            attach_to_existing=False,
            headless_mode=False,
            user_id=None,
            git_provider_tokens=None,
            ssh_host="worker",
            ssh_user="sandboxuser",
            ssh_key="/run/secrets/ssh_key",
        ):
            super().__init__(
                config,
                event_stream,
                llm_registry,
                sid=sid,
                plugins=plugins,
                env_vars=env_vars,
                status_callback=status_callback,
                attach_to_existing=attach_to_existing,
                headless_mode=headless_mode,
                user_id=user_id,
                git_provider_tokens=git_provider_tokens,
            )
            self._ssh_host = ssh_host
            self._ssh_user = ssh_user
            self._ssh_key_src = ssh_key
            self._ssh_key = None      # root-owned 0600 copy, set in connect()
            self._key_tmpdir = None
            self._ssh_opts = None
            self._ssh_base = None

        async def connect(self) -> None:
            # Copy key to root-owned tempfile with 0600 — ssh client refuses keys
            # that are group/world readable. The mounted key may be 644.
            self._key_tmpdir = tempfile.mkdtemp()
            key_copy = os.path.join(self._key_tmpdir, "id")
            shutil.copy2(self._ssh_key_src, key_copy)
            os.chmod(key_copy, stat.S_IRUSR | stat.S_IWUSR)
            self._ssh_key = key_copy

            self._ssh_opts = [
                "-i", self._ssh_key,
                "-o", "StrictHostKeyChecking=no",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=30",
            ]
            self._ssh_base = (
                ["ssh"] + self._ssh_opts + [f"{self._ssh_user}@{self._ssh_host}"]
            )

            # Verify connectivity
            result = subprocess.run(
                self._ssh_base + ["echo", "ok"],
                capture_output=True, text=True, timeout=30,
            )
            if result.returncode != 0:
                raise ConnectionError(
                    f"SSH test failed (exit {result.returncode}): {result.stderr.strip()}"
                )
            self._runtime_initialized = True
            print("[runner] SSH connected to worker", flush=True)

        def _ssh_run(self, command: str, timeout: int = 300) -> tuple[int, str]:
            """Run shell command on worker via ssh. Returns (exit_code, combined_output)."""
            proc = subprocess.run(
                self._ssh_base + ["bash", "-s"],
                input=command.encode(),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=timeout,
            )
            output = proc.stdout.decode(errors="replace")
            return proc.returncode, output

        def run(self, action):
            try:
                exit_code, output = self._ssh_run(action.command)
                return CmdOutputObservation(
                    content=output,
                    command=action.command,
                    metadata={"exit_code": exit_code},
                )
            except subprocess.TimeoutExpired:
                return ErrorObservation(f"command timed out: {action.command[:100]}")
            except Exception as exc:
                return ErrorObservation(f"run failed: {exc}")

        def run_ipython(self, action):
            return ErrorObservation("IPython not supported in SSHRuntime")

        def read(self, action):
            try:
                exit_code, output = self._ssh_run(f"cat {action.path!r}")
                if exit_code != 0:
                    return ErrorObservation(f"read failed (exit {exit_code}): {output}")
                return FileReadObservation(content=output, path=action.path)
            except Exception as exc:
                return ErrorObservation(f"read failed: {exc}")

        def write(self, action):
            try:
                self._ssh_run(f"mkdir -p {str(Path(action.path).parent)!r}")
                proc = subprocess.run(
                    self._ssh_base + [f"tee {action.path!r} > /dev/null"],
                    input=action.content.encode(),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    timeout=60,
                )
                if proc.returncode != 0:
                    err = proc.stdout.decode(errors="replace")
                    return ErrorObservation(f"write failed: {err}")
                return FileWriteObservation(content="", path=action.path)
            except Exception as exc:
                return ErrorObservation(f"write failed: {exc}")

        def edit(self, action):
            try:
                # Read current content
                exit_code, old_content = self._ssh_run(f"cat {action.path!r}")
                prev_exist = exit_code == 0
                if not prev_exist:
                    old_content = ""

                if action.old_str:
                    if action.old_str not in old_content:
                        return ErrorObservation(
                            f"edit failed: old_str not found in {action.path}"
                        )
                    new_content = old_content.replace(action.old_str, action.new_str or "", 1)
                else:
                    new_content = action.file_text or old_content

                # Write new content
                self._ssh_run(f"mkdir -p {str(Path(action.path).parent)!r}")
                proc = subprocess.run(
                    self._ssh_base + [f"tee {action.path!r} > /dev/null"],
                    input=new_content.encode(),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    timeout=60,
                )
                if proc.returncode != 0:
                    err = proc.stdout.decode(errors="replace")
                    return ErrorObservation(f"edit write failed: {err}")

                return FileEditObservation(
                    content="",
                    path=action.path,
                    prev_exist=prev_exist,
                    old_content=old_content,
                    new_content=new_content,
                )
            except Exception as exc:
                return ErrorObservation(f"edit failed: {exc}")

        def browse(self, action):
            return ErrorObservation("Browser not supported in SSHRuntime")

        def browse_interactive(self, action):
            return ErrorObservation("Browser not supported in SSHRuntime")

        async def call_tool_mcp(self, action):
            return ErrorObservation("MCP not supported in SSHRuntime")

        def get_mcp_config(self, extra_stdio_servers=None):
            from openhands.core.config.mcp_config import MCPConfig
            return MCPConfig()

        def copy_to(self, host_src: str, sandbox_dest: str, recursive: bool = False):
            scp_opts = self._ssh_opts + (["-r"] if recursive else [])
            subprocess.run(
                ["scp"] + scp_opts + [host_src, f"{self._ssh_user}@{self._ssh_host}:{sandbox_dest}"],
                check=True, capture_output=True, timeout=120,
            )

        def list_files(self, path: str | None = None) -> list[str]:
            exit_code, output = self._ssh_run(f"ls {path or '/workspace'!r}")
            if exit_code != 0:
                return []
            return [line for line in output.splitlines() if line]

        def copy_from(self, path: str) -> Path:
            tmp = Path(tempfile.mktemp(suffix=".bin"))
            subprocess.run(
                ["scp"] + self._ssh_opts
                + [f"{self._ssh_user}@{self._ssh_host}:{path}", str(tmp)],
                check=True, capture_output=True, timeout=120,
            )
            return tmp

        def close(self) -> None:
            if self._key_tmpdir:
                shutil.rmtree(self._key_tmpdir, ignore_errors=True)
                self._key_tmpdir = None
                self._ssh_key = None

    return SSHRuntime


async def run_agent(task: str) -> dict:
    from openhands.core.config import OpenHandsConfig, LLMConfig
    from openhands.core.main import run_controller
    from openhands.core.setup import generate_sid, get_file_store
    from openhands.llm.llm_registry import LLMRegistry
    from openhands.events import EventStream
    from openhands.events.action import MessageAction

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

    config = OpenHandsConfig(
        workspace_base="/workspace",
        workspace_mount_path="/workspace",
        workspace_mount_path_in_sandbox="/workspace",
        run_as_openhands=False,
    )
    config.llms["llm"] = llm_config

    sid = generate_sid(config)
    file_store = get_file_store(config.file_store, config.file_store_path)
    event_stream = EventStream(sid, file_store)
    llm_registry = LLMRegistry(config)

    SSHRuntime = _make_ssh_runtime_class()
    runtime = SSHRuntime(
        config=config,
        event_stream=event_stream,
        llm_registry=llm_registry,
        sid=sid,
        headless_mode=True,
        ssh_host=os.environ.get("SSH_HOST", "worker"),
        ssh_user=os.environ.get("SSH_USER", "sandboxuser"),
        ssh_key=os.environ.get("SSH_KEY", "/run/secrets/ssh_key"),
    )

    await runtime.connect()

    try:
        state = await run_controller(
            config=config,
            initial_user_action=MessageAction(content=task),
            sid=sid,
            runtime=runtime,
            headless_mode=True,
        )
    finally:
        runtime.close()

    session_tokens: dict = {}
    session_cost = 0.0

    if state is not None and getattr(state, "metrics", None) is not None:
        usage = state.metrics.accumulated_token_usage
        session_tokens = {
            "prompt_tokens": int(getattr(usage, "prompt_tokens", 0)),
            "completion_tokens": int(getattr(usage, "completion_tokens", 0)),
            "cache_read_tokens": int(getattr(usage, "cache_read_tokens", 0)),
            "cache_write_tokens": int(getattr(usage, "cache_write_tokens", 0)),
        }
        session_cost = float(state.metrics.accumulated_cost)

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
