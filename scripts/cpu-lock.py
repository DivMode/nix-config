"""Label concurrent runs without blocking; record locks track liveness only."""

import argparse
import ctypes
from datetime import datetime, timezone
import errno
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


# Heavy work runs below interactive apps. Never raise priority a caller lowered.
BACKGROUND_NICE = 10


def lower_priority():
    # Runs before spawning (or in Popen's child): a refusal never stops the command,
    # which then simply runs at its inherited priority.
    try:
        if os.getpriority(os.PRIO_PROCESS, 0) < BACKGROUND_NICE:
            os.setpriority(os.PRIO_PROCESS, 0, BACKGROUND_NICE)
    except OSError:
        pass


def spawn_utility(command, environment):
    """Spawn directly with taskpolicy's inheritable macOS utility QoS clamp."""
    # Darwin's spawn.h defines both opaque objects as void pointers, and
    # sys/_types/_sigset_t.h defines sigset_t as uint32_t.
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    object_pointer = ctypes.POINTER(ctypes.c_void_p)
    strings = ctypes.POINTER(ctypes.c_char_p)
    for name, types in (
        ("posix_spawnattr_init", [object_pointer]),
        ("posix_spawnattr_destroy", [object_pointer]),
        ("posix_spawnattr_setflags", [object_pointer, ctypes.c_short]),
        ("posix_spawnattr_setsigdefault", [object_pointer, ctypes.POINTER(ctypes.c_uint32)]),
        ("posix_spawnattr_set_qos_clamp_np", [object_pointer, ctypes.c_uint64]),
        ("posix_spawn_file_actions_init", [object_pointer]),
        ("posix_spawn_file_actions_destroy", [object_pointer]),
        ("posix_spawn_file_actions_addinherit_np", [object_pointer, ctypes.c_int]),
        ("posix_spawn", [ctypes.POINTER(ctypes.c_int), ctypes.c_char_p,
                         object_pointer, object_pointer, strings, strings]),
    ):
        function = getattr(libc, name)
        function.argtypes = types
        function.restype = ctypes.c_int

    def check(error):
        # These APIs return errno, rather than setting ctypes' errno.
        if error:
            raise OSError(error, os.strerror(error), command[0])

    argv = (ctypes.c_char_p * (len(command) + 1))(*map(os.fsencode, command))
    envp = (ctypes.c_char_p * (len(environment) + 1))(
        *(os.fsencode(f"{key}={value}") for key, value in environment.items()))
    attr = ctypes.c_void_p()
    actions = ctypes.c_void_p()
    check(libc.posix_spawnattr_init(ctypes.byref(attr)))
    try:
        # sys/spawn.h: SETSIGDEF | SETSID | CLOEXEC_DEFAULT, preserving Popen's
        # restored signal defaults, new session, and close_fds=True behavior.
        check(libc.posix_spawnattr_setflags(ctypes.byref(attr), 0x0004 | 0x0400 | 0x4000))
        defaults = ctypes.c_uint32(sum(1 << (getattr(signal, name) - 1)
                                      for name in ("SIGPIPE", "SIGXFZ", "SIGXFSZ")
                                      if hasattr(signal, name)))
        check(libc.posix_spawnattr_setsigdefault(ctypes.byref(attr), ctypes.byref(defaults)))
        # xnu/bsd/sys/spawn_internal.h: POSIX_SPAWN_PROC_CLAMP_UTILITY = 1.
        # system_cmds/taskpolicy/taskpolicy.c uses this same attribute for -c utility.
        check(libc.posix_spawnattr_set_qos_clamp_np(ctypes.byref(attr), 1))
        check(libc.posix_spawn_file_actions_init(ctypes.byref(actions)))
        try:
            for fd in (0, 1, 2):
                try:
                    flags = fcntl.fcntl(fd, fcntl.F_GETFD)
                except OSError as error:
                    if error.errno != errno.EBADF:
                        raise
                else:
                    # A closed standard stream can be reused by publish() for
                    # its CLOEXEC record; preserve exec's close-on-exec behavior.
                    if not flags & fcntl.FD_CLOEXEC:
                        check(libc.posix_spawn_file_actions_addinherit_np(ctypes.byref(actions), fd))
            # posix_spawnp shell-interprets ENOEXEC (Libc/sys/posix_spawn.c).
            # Use posix_spawn and Popen's PATH search/error precedence instead.
            paths = ([command[0]] if os.path.dirname(command[0]) else
                     [os.path.join(path, command[0]) for path in os.get_exec_path(environment)])
            saved_error = None
            pid = ctypes.c_int()
            for path in paths:
                error = libc.posix_spawn(ctypes.byref(pid), os.fsencode(path),
                                         ctypes.byref(actions), ctypes.byref(attr), argv, envp)
                if not error:
                    return pid.value
                if saved_error is None and error not in (errno.ENOENT, errno.ENOTDIR):
                    saved_error = error
            check(saved_error or error)
        finally:
            libc.posix_spawn_file_actions_destroy(ctypes.byref(actions))
    finally:
        libc.posix_spawnattr_destroy(ctypes.byref(attr))


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
    child_pid = None
    received = None

    def forward(signum, _frame):
        nonlocal received
        if child_pid is None:
            received = signum
        else:
            # The child leads its own session, so the terminal and an outer
            # killer reach only this wrapper: signal the whole group, or a
            # `just` child dies and leaves its cargo and test processes running.
            try:
                os.killpg(child_pid, signum)
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
            if sys.platform == "darwin":
                lower_priority()
                child_pid = spawn_utility(args.command, environment)
            else:
                child = subprocess.Popen(args.command, env=environment, close_fds=True,
                                         start_new_session=True, preexec_fn=lower_priority)
                child_pid = child.pid
            if received is not None:
                forward(received, None)
            code = (os.waitstatus_to_exitcode(os.waitpid(child_pid, 0)[1])
                    if sys.platform == "darwin" else child.wait())
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
