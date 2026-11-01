"""Keep a managed hook's failures and output from controlling an agent turn."""

import json
import math
import os
import selectors
import signal
import subprocess
import sys
import time


OUTPUT_LIMIT = 65536
STDERR_LIMIT = 240


def permission_denial(output):
    """The sole control a deny hook may return, shared with the build gate."""
    try:
        value = json.loads(output)
    except (ValueError, UnicodeError, RecursionError):
        return None
    if not isinstance(value, dict) or set(value) != {"hookSpecificOutput"}:
        return None
    specific = value["hookSpecificOutput"]
    if (not isinstance(specific, dict)
            or not set(specific) <= {"hookEventName", "permissionDecision", "permissionDecisionReason"}
            or specific.get("hookEventName") != "PreToolUse"
            or specific.get("permissionDecision") != "deny"
            or not isinstance(specific.get("permissionDecisionReason", ""), str)):
        return None
    return value


def emit(fd, data):
    # One nonblocking, atomic pipe write: an unread client pipe must not stall
    # the supervisor. Oversized denials are dropped rather than sent partially.
    if len(data) > os.fpathconf(fd, "PC_PIPE_BUF"):
        return
    os.set_blocking(fd, False)
    os.write(fd, data)


def report(data):
    text = " ".join(data.decode("utf-8", "replace").split())
    text = "".join(char for char in text if char.isprintable())
    line = text.encode("utf-8")[:STDERR_LIMIT].decode("utf-8", "ignore")
    if line:
        try:
            emit(2, line.encode("utf-8") + b"\n")
        except OSError:
            pass


def main(arguments):
    started = time.monotonic()
    if (len(arguments) < 6 or arguments[0] != "--kind"
            or arguments[2] != "--timeout" or arguments[4] != "--"):
        return
    kind, timeout = arguments[1], float(arguments[3])
    if kind not in {"observe", "deny"} or not math.isfinite(timeout) or not 0 < timeout <= 15:
        return
    # Leave up to a second for interpreter startup, process cleanup and output
    # before the client's own deadline. Even the one-second fixtures get 0.5s.
    deadline = started + timeout - min(1.0, timeout / 2)
    process = None
    stdout, stderr = bytearray(), bytearray()
    overflow = False
    succeeded = False
    try:
        process = subprocess.Popen(arguments[5:], stdin=sys.stdin.buffer,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        with selectors.DefaultSelector() as selector:
            for stream, buffer, limit in [(process.stdout, stdout, OUTPUT_LIMIT),
                                          (process.stderr, stderr, STDERR_LIMIT * 4)]:
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, (buffer, limit))
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                for key, _events in selector.select(remaining):
                    chunk = os.read(key.fd, 8192)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    buffer, limit = key.data
                    if buffer is stdout and len(buffer) + len(chunk) > limit:
                        overflow = True
                    buffer.extend(chunk[:max(0, limit - len(buffer))])
            remaining = deadline - time.monotonic()
            if not selector.get_map() and remaining > 0:
                succeeded = process.wait(timeout=remaining) == 0
    except subprocess.TimeoutExpired:
        pass
    finally:
        if process is not None:
            # Always clean up the group, including descendants whose parent
            # already exited or which closed their output pipes before hanging.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            for stream in [process.stdout, process.stderr]:
                stream.close()
            try:
                process.wait(timeout=0.1)
            except subprocess.TimeoutExpired:
                pass

    report(stderr)
    if kind == "deny" and succeeded and not overflow:
        denial = permission_denial(stdout)
        if denial is not None:
            emit(1, json.dumps(denial, separators=(",", ":")).encode("utf-8") + b"\n")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except BaseException:
        # Own errors are fail-open too. Never return an inner exit status or
        # partial/unchecked stdout to either client.
        pass
    sys.exit(0)
