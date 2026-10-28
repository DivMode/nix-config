"""Cooperative, per-user CPU reader/writer lock. flock owns the lock; JSON describes it."""

import argparse
from datetime import datetime, timezone
import fcntl
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def positive_seconds(value):
    try:
        seconds = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("--wait must be a positive number")
    if not math.isfinite(seconds) or seconds <= 0:
        raise argparse.ArgumentTypeError("--wait must be a positive number")
    return seconds


def arguments():
    parser = argparse.ArgumentParser(prog="cpu-lock", allow_abbrev=False)
    # The Home Manager wrapper supplies the sole production path.
    parser.add_argument("directory", type=Path)
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("status", allow_abbrev=False)
    run = commands.add_parser("run", allow_abbrev=False)
    modes = run.add_mutually_exclusive_group(required=True)
    modes.add_argument("--shared", dest="mode", action="store_const", const="shared")
    modes.add_argument("--exclusive", dest="mode", action="store_const", const="exclusive")
    run.add_argument("--wait", required=True, type=positive_seconds)
    run.add_argument("--label", required=True)
    run.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.action == "run":
        if args.command[:1] == ["--"]:
            args.command = args.command[1:]
        if not args.command:
            parser.error("run requires a command")
        if not args.label.strip():
            parser.error("run requires a non-empty label")
    return args


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def records(directory):
    for path in sorted(directory.glob("[0-9]*")):
        if not path.name.isdecimal():
            continue
        try:
            record = json.loads(path.read_text())
        except FileNotFoundError:
            continue  # A release raced the directory listing.
        yield record, alive(record["pid"])


def describe(record):
    # JSON quoting keeps labels and paths containing newlines on one output line.
    return (
        f'{record["mode"]} label={json.dumps(record["label"])} '
        f'pid={record["pid"]} start={record["start"]} cwd={json.dumps(record["cwd"])}'
    )


def status(directory):
    lines = []
    for name, kind in (("holders", "holder"), ("waiting", "exclusive waiter")):
        for record, live in records(directory / name):
            lines.append(f'{kind if live else "stale " + kind}: {describe(record)}')
    print("\n".join(lines) if lines else "idle")


def publish(path, record):
    temporary = path.with_suffix(".tmp")
    try:
        temporary.write_text(json.dumps(record) + "\n")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def blockers(directory, own_pid):
    return "; ".join(
        f"{kind}: {describe(record)}"
        for name, kind in (("holders", "holder"), ("waiting", "exclusive waiter"))
        for record, live in records(directory / name)
        if live and record["pid"] != own_pid
    ) or "holders changing (no record yet)"


def run(args, directory, command_umask):
    held = os.environ.get("CPU_LOCK_HELD")
    owner = os.environ.get("CPU_LOCK_OWNER", "")
    if os.environ.get("CPU_LOCK_DIRECTORY") == str(directory) and owner.isdecimal():
        # An inherited environment from a leaked daemon must not bypass a released lock.
        inherited = next(
            (r for r, live in records(directory / "holders")
             if live and r["pid"] == int(owner) and r["mode"] == held),
            None,
        )
        if inherited:
            if held == "shared" and args.mode == "exclusive":
                print("cpu-lock: exclusive inside shared would wait on itself", file=sys.stderr)
                return 2
            os.umask(command_umask)
            os.execvpe(args.command[0], args.command, os.environ)

    deadline = time.monotonic() + args.wait
    pid = os.getpid()
    holder = directory / "holders" / str(pid)
    waiter = directory / "waiting" / str(pid)
    record = {
        "mode": args.mode,
        "label": args.label,
        "pid": pid,
        "start": datetime.now(timezone.utc).isoformat(),
        "cwd": os.getcwd(),
    }
    child = None
    received = None
    reported = False

    def forward(signum, _frame):
        nonlocal received
        if child is None:
            received = signum
        else:
            # The child leads its own session, so the terminal and an outer
            # killer reach only this wrapper: signal the whole group, or a
            # `just` child dies and leaves its cargo and test processes running.
            try:
                os.killpg(child.pid, signum)
            except ProcessLookupError:
                pass

    def pause():
        nonlocal reported
        if received is not None:
            raise InterruptedError
        if not reported:
            print(f"cpu-lock: waiting on {blockers(directory, pid)}", file=sys.stderr, flush=True)
            reported = True
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError
        time.sleep(min(0.05, remaining))

    def acquire(fd, mode):
        while True:
            if received is not None:
                raise InterruptedError
            if time.monotonic() >= deadline:
                raise TimeoutError
            try:
                fcntl.flock(fd, mode | fcntl.LOCK_NB)
                return
            except BlockingIOError:
                pause()

    previous = {sig: signal.signal(sig, forward) for sig in
                (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        with (directory / "turnstile").open("a") as gate, (directory / "main").open("a") as main:
            if args.mode == "exclusive":
                publish(waiter, record)
            try:
                while True:
                    acquire(gate, fcntl.LOCK_EX)
                    # NB polling alone has no fairness guarantee. Announced writers
                    # also take priority over readers waiting for the turnstile.
                    if args.mode == "shared" and any(live for _, live in records(directory / "waiting")):
                        fcntl.flock(gate, fcntl.LOCK_UN)
                        pause()
                        continue
                    acquire(main, fcntl.LOCK_SH if args.mode == "shared" else fcntl.LOCK_EX)
                    break
                record["start"] = datetime.now(timezone.utc).isoformat()
                publish(holder, record)
                waiter.unlink(missing_ok=True)
                fcntl.flock(gate, fcntl.LOCK_UN)
                if received is not None:
                    raise InterruptedError
                environment = dict(os.environ, CPU_LOCK_HELD=args.mode,
                                   CPU_LOCK_DIRECTORY=str(directory), CPU_LOCK_OWNER=str(pid))
                # A new session avoids delivering terminal signals twice. Neither
                # the command nor any daemon it leaves behind inherits lock fds.
                os.umask(command_umask)
                child = subprocess.Popen(args.command, env=environment, close_fds=True,
                                         start_new_session=True)
                if received is not None:
                    forward(received, None)
                code = child.wait()
                return code if code >= 0 else 128 - code
            finally:
                holder.unlink(missing_ok=True)
                waiter.unlink(missing_ok=True)
    except TimeoutError:
        print(f"cpu-lock: timed out after {args.wait:g}s waiting on {blockers(directory, pid)}",
              file=sys.stderr)
        return 75
    except InterruptedError:
        return 128 + received
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def main():
    args = arguments()
    # CPU_LOCK_DIR is a test-only override; production uses the wrapper's path.
    directory = Path(os.environ.get("CPU_LOCK_DIR", args.directory)).resolve()
    command_umask = os.umask(0o077)
    try:
        if args.action == "status":
            status(directory)
            return 0
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        for name in ("holders", "waiting"):
            (directory / name).mkdir(mode=0o700, exist_ok=True)
        return run(args, directory, command_umask)
    except OSError as error:
        print(f"cpu-lock: {error}", file=sys.stderr)
        return 127 if isinstance(error, FileNotFoundError) else 126
    finally:
        os.umask(command_umask)


if __name__ == "__main__":
    sys.exit(main())
