"""Label concurrent runs without blocking; record locks track liveness only."""

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
    modes.add_argument("--exclusive", dest="mode", action="store_const", const="shared",
                       help="compatibility alias for --shared; never blocks")
    run.add_argument("--wait", type=positive_seconds,
                     help="accepted for compatibility; never waits")
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


def records(directory):
    for path in sorted(directory.glob("[0-9]*")):
        if not path.name.isdecimal():
            continue
        try:
            with path.open() as file:
                record = json.load(file)
                # Each wrapper locks only its own record. The kernel releases it
                # on any death, whereas a dead wrapper's pid can be reused.
                try:
                    fcntl.flock(file, fcntl.LOCK_SH | fcntl.LOCK_NB)
                    live = False
                except BlockingIOError:
                    live = True
        except FileNotFoundError:
            continue  # A release raced the directory listing.
        yield record, live


def describe(record):
    # JSON quoting keeps labels and paths containing newlines on one output line.
    return (
        f'{record["mode"]} label={json.dumps(record["label"])} '
        f'pid={record["pid"]} start={record["start"]} cwd={json.dumps(record["cwd"])}'
    )


def status(directory):
    lines = []
    for record, live in records(directory / "holders"):
        lines.append(f'{"holder" if live else "stale holder"}: {describe(record)}')
    print("\n".join(lines) if lines else "idle")


def publish(path, record):
    """Publish a record that stays live until the returned file is closed."""
    temporary = path.with_suffix(".tmp")
    file = temporary.open("w")
    try:
        fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        file.write(json.dumps(record) + "\n")
        file.flush()
        temporary.replace(path)
        return file
    except BaseException:
        file.close()
        raise
    finally:
        temporary.unlink(missing_ok=True)


def run(args, directory, command_umask):
    pid = os.getpid()
    holder = directory / "holders" / str(pid)
    record = {
        "mode": args.mode,
        "label": args.label,
        "pid": pid,
        "start": datetime.now(timezone.utc).isoformat(),
        "cwd": os.getcwd(),
    }
    child = None
    received = None

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

    previous = {sig: signal.signal(sig, forward) for sig in
                (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        with publish(holder, record):
            if received is not None:
                return 128 + received
            environment = dict(os.environ, CPU_LOCK_HELD=args.mode,
                               CPU_LOCK_DIRECTORY=str(directory), CPU_LOCK_OWNER=str(pid))
            # A new session avoids delivering terminal signals twice. Neither
            # the command nor any daemon it leaves behind inherits record fds.
            os.umask(command_umask)
            child = subprocess.Popen(args.command, env=environment, close_fds=True,
                                     start_new_session=True)
            if received is not None:
                forward(received, None)
            code = child.wait()
            return code if code >= 0 else 128 - code
    finally:
        holder.unlink(missing_ok=True)
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
        (directory / "holders").mkdir(mode=0o700, exist_ok=True)
        return run(args, directory, command_umask)
    except OSError as error:
        print(f"cpu-lock: {error}", file=sys.stderr)
        return 127 if isinstance(error, FileNotFoundError) else 126
    finally:
        os.umask(command_umask)


if __name__ == "__main__":
    sys.exit(main())
