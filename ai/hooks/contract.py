"""Build gate for managed hooks; execute commands without a shell or user tools."""

import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import tomllib

from supervisor import permission_denial


FORBIDDEN_EVENTS = {"Stop", "SubagentStop", "PreCompact", "UserPromptSubmit"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def payload(event, command="ls"):
    return json.dumps({
        "hook_event_name": event,
        "session_id": "hook-contract",
        "cwd": "/nonexistent/agent-hook-contract/cwd",
        "source": "startup",
        "tool_name": "Bash",
        "tool_input": {"command": command},
    })


def has_control(value):
    if isinstance(value, dict):
        return ("decision" in value or value.get("continue") is False
                or value.get("permissionDecision") == "deny"
                or any(has_control(item) for item in value.values()))
    return isinstance(value, list) and any(has_control(item) for item in value)


def output_denies(hook, output):
    if not output.strip():
        return False
    if hook["kind"] == "observe":
        # Observers may print text. Inspect whole JSON and JSON lines, including
        # nested controls, so pretty-printing cannot conceal a blocking result.
        for text in [output, *output.splitlines()]:
            try:
                value = json.loads(text)
            except ValueError:
                continue
            require(not has_control(value), "observer emitted blocking/continuation control")
        return False
    require(permission_denial(output) is not None,
            "deny hook emitted something other than PreToolUse permissionDecision deny")
    return True


def run(hook, text, environment, scratch, env_program, bare_path):
    command = [env_program, "-i", f"PATH={bare_path}", f"TMPDIR={scratch}"]
    command += [f"{key}={value}" for key, value in environment.items()]
    command += hook["argv"]
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, cwd=scratch,
                          start_new_session=True) as process:
        try:
            stdout, stderr = process.communicate(text, timeout=hook["timeout"])
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise ValueError("hook exceeded its declared timeout") from None
    require(process.returncode == 0, f"exit {process.returncode}: {stderr.strip()}")
    if hook.get("supervised"):
        require(len(stderr.encode("utf-8")) <= 241 and stderr.count("\n") <= 1,
                "supervisor stderr must be one short bounded line")
        if hook["kind"] == "observe":
            require(stdout == "", "supervised observer emitted stdout")
    return output_denies(hook, stdout)


def rendered_hooks(handlers, client):
    events = {}
    for hook in handlers:
        if hook["client"] == client:
            events.setdefault(hook["event"], []).append({
                "matcher": hook["matcher"],
                "hooks": [{"type": "command", "command": hook["command"], "timeout": hook["timeout"]}],
            })
    return events


def main():
    manifest, claude_file, codex_file, destination, env_program, bare_path = sys.argv[1:]
    handlers = json.loads(Path(manifest).read_text())
    for hook in handlers:
        require(hook["event"] not in FORBIDDEN_EVENTS, f"forbidden event {hook['event']}")
        require(hook["kind"] in {"observe", "deny"}, "unknown hook kind")
        require(hook["kind"] != "deny" or hook["event"] == "PreToolUse", "deny requires PreToolUse")
        require(type(hook["timeout"]) is int and 0 < hook["timeout"] <= 15,
                "timeout must be explicit and between 1 and 15 seconds")
        require(hook["client"] in {"claude", "codex"}, "unknown hook client")
        require(isinstance(hook["argv"], list) and bool(hook["argv"])
                and all(isinstance(arg, str) for arg in hook["argv"])
                and shlex.split(hook["command"]) == hook["argv"], "hook command differs from argv")

    claude = json.loads(Path(claude_file).read_text())
    codex = tomllib.loads(Path(codex_file).read_text())
    require(isinstance(claude, dict) and claude.get("allowManagedHooksOnly") is True,
            "Claude managed settings must be an object with managed-only hooks")
    require(codex.get("allow_managed_hooks_only") is True, "Codex must use managed-only hooks")
    require(codex.get("features", {}).get("hooks") is True, "Codex managed hooks feature must be pinned on")
    for client, config in [("claude", claude), ("codex", codex)]:
        require(config["hooks"] == rendered_hooks(handlers, client), f"{client} hooks differ from declarations")

    with tempfile.TemporaryDirectory(prefix="agent-hook-contract-") as scratch:
        for hook in handlers:
            try:
                for environment in hook.get("environments", [{}]):
                    for text in ["{", "", "null", payload(hook["event"])]:
                        require(not run(hook, text, environment, scratch, env_program, bare_path),
                                "denied malformed or harmless input")
                for probe in hook.get("probes", []):
                    denied = run(hook, payload(hook["event"], probe["command"]),
                                 probe.get("environment", {}), scratch, env_program, bare_path)
                    require(denied == probe["deny"], f"wrong decision for {probe['command']!r}")
                    print(f"PASS {hook['name']}: {probe['command']!r}, {probe.get('environment', {})} -> {'deny' if denied else 'allow'}", flush=True)
            except (ValueError, OSError) as error:
                raise ValueError(f"{hook['name']}: {error}") from None
            print(f"PASS {hook['name']}: malformed/empty/null/harmless inputs and output controls", flush=True)

    output = Path(destination)
    output.mkdir()
    shutil.copyfile(claude_file, output / "managed-settings.json")
    shutil.copyfile(codex_file, output / "requirements.toml")
    print("PASS managed JSON/TOML match declarations; hook contract passed", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        sys.exit(f"agent-hooks: {error}")
