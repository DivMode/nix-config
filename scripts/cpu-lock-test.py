"""Exercise the real CLI and kernel locks with independent concurrent processes."""

from datetime import datetime
import errno
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT = Path(__file__).with_name("cpu-lock.py")
THIS = Path(__file__).resolve()


def observed_priority():
    result = {"nice": os.getpriority(os.PRIO_PROCESS, 0)}
    if sys.platform == "darwin":
        import ctypes

        # Darwin sys/proc_info.h: PROC_PIDTHREADID64INFO returns proc_threadinfo.
        # Its pth_maxpriority is the kernel's effective limit, unlike pthread's
        # requested QoS. xnu/osfmk/kern/task_policy.c caps it at the task clamp.
        class ThreadInfo(ctypes.Structure):
            _fields_ = [("user_time", ctypes.c_uint64), ("system_time", ctypes.c_uint64)] + [
                (name, ctypes.c_int32) for name in (
                    "cpu_usage", "policy", "run_state", "flags", "sleep_time",
                    "current_priority", "priority", "max_priority")
            ] + [("name", ctypes.c_char * 64)]

        libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        libc.pthread_threadid_np.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint64)]
        libc.pthread_threadid_np.restype = ctypes.c_int
        libc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                     ctypes.c_void_p, ctypes.c_int]
        libc.proc_pidinfo.restype = ctypes.c_int
        thread_id = ctypes.c_uint64()
        error = libc.pthread_threadid_np(None, ctypes.byref(thread_id))
        if error:
            raise OSError(error, os.strerror(error))
        info = ThreadInfo()
        size = libc.proc_pidinfo(os.getpid(), 15, thread_id.value,
                                ctypes.byref(info), ctypes.sizeof(info))
        if size != ctypes.sizeof(info):
            raise RuntimeError(f"proc_pidinfo returned {size} bytes: errno={ctypes.get_errno()}")
        result["max_priority"] = info.max_priority
    return result


def worker():
    marker = Path(sys.argv[2])
    action = sys.argv[3]
    temporary = marker.with_suffix(".tmp")
    temporary.write_text(json.dumps({"time": time.monotonic(), "pid": os.getpid(),
                                    "held": os.environ.get("CPU_LOCK_HELD"),
                                    "directory": os.environ.get("CPU_LOCK_DIRECTORY")}))
    temporary.replace(marker)
    if action == "sleep":
        time.sleep(float(sys.argv[4]))
    elif action == "exit":
        sys.exit(int(sys.argv[4]))
    elif action == "die":
        os.kill(os.getpid(), int(sys.argv[4]))
    elif action == "priority":
        print(json.dumps(observed_priority()), flush=True)
    elif action == "launch-priority":
        import importlib.util
        from unittest import mock
        print(json.dumps(observed_priority()), flush=True)
        spec = importlib.util.spec_from_file_location("cpu_lock_module", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        # Change only the target, so the real lowering hook must act even when
        # the suite already inherits nice 10. No scheduler syscall is mocked.
        target = int(sys.argv[4])
        sys.argv = [str(SCRIPT), sys.argv[5], "run", "--shared", "--label", "priority", "--",
                    sys.executable, str(THIS), "worker", str(marker), "priority"]
        with mock.patch.object(module, "BACKGROUND_NICE", target):
            sys.exit(module.main())
    elif action == "signal":
        def received(signum, _frame):
            marker.with_suffix(".signal").write_text(str(signum))
            limit = time.monotonic() + 60
            while not marker.with_suffix(".release").exists():
                if time.monotonic() >= limit:
                    sys.exit(99)
                time.sleep(0.01)
            sys.exit(128 + signum)
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, received)
        marker.with_suffix(".ready").touch()
        while True:
            signal.pause()
    elif action == "group":
        # A command that outlives its own signal, like `just` waiting on cargo:
        # only the grandchild can observe whether the signal reached the group.
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        grandchild = subprocess.Popen([sys.executable, str(THIS), "worker", str(marker), "signal"],
                                      preexec_fn=lambda: [signal.signal(s, signal.SIG_DFL) for s in
                                                          (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)])
        sys.exit(grandchild.wait())
    elif action == "daemon":
        daemon = subprocess.Popen([sys.executable, str(THIS), "worker",
                                   str(marker.with_name(marker.name + "-daemon")), "hold"],
                                  stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, close_fds=False)
        marker.with_suffix(".pid").write_text(str(daemon.pid))
    if action in ("hold", "daemon"):
        limit = time.monotonic() + 60
        while not marker.with_suffix(".release").exists():
            if time.monotonic() > limit:
                sys.exit(99)
            time.sleep(0.01)
    marker.with_suffix(".end").write_text(str(time.monotonic()))


class CpuLockTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.directory = self.root / "lock"
        self.environment = dict(os.environ, CPU_LOCK_DIR=str(self.directory))
        self.processes = []
        self.addCleanup(self.cleanup)

    def cleanup(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
            try:
                process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
        self.temporary.cleanup()

    def cli(self, *args):
        return [sys.executable, str(SCRIPT), str(self.root / "unused-default"), *args]

    def start(self, mode, label, action="hold", *extra, wait=None, command=None, close_stdin=False):
        marker = self.root / label
        command = command or [sys.executable, str(THIS), "worker", str(marker), action, *extra]
        wait_args = [] if wait is None else ["--wait", wait]
        process = subprocess.Popen(self.cli("run", "--" + mode, *wait_args,
                                           "--label", label, "--", *command),
                                   env=self.environment, cwd=self.root, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   preexec_fn=(lambda: os.closerange(0, 1)) if close_stdin else None)
        self.processes.append(process)
        return process, marker

    def until(self, predicate):
        limit = time.monotonic() + 30
        while not predicate():
            if time.monotonic() >= limit:
                self.fail("condition did not become true within 30s")
            time.sleep(0.01)

    def ready(self, marker):
        self.until(marker.exists)
        return json.loads(marker.read_text())

    def release(self, marker):
        marker.with_suffix(".release").touch()

    def finish(self, process, code=0):
        out, err = process.communicate(timeout=30)
        self.assertEqual(process.returncode, code, (out, err))
        return out, err

    def status(self):
        result = subprocess.run(self.cli("status"), env=self.environment,
                                capture_output=True, text=True, check=True)
        return result.stdout

    def test_shared_sleep_runs_overlap(self):
        first, a = self.start("shared", "first", "sleep", "2")
        second, b = self.start("shared", "second", "sleep", "2")
        self.ready(a)
        self.ready(b)
        self.finish(first)
        self.finish(second)
        starts = [self.ready(marker)["time"] for marker in (a, b)]
        ends = [float(marker.with_suffix(".end").read_text()) for marker in (a, b)]
        self.assertLess(max(ends) - min(starts), 3.5)
        self.assertLess(max(self.ready(a)["time"], self.ready(b)["time"]),
                        min(float(a.with_suffix(".end").read_text()),
                            float(b.with_suffix(".end").read_text())))

    def test_exclusive_holder_overlaps_both_modes(self):
        holder, a = self.start("exclusive", "holder", "sleep", "2")
        self.ready(a)
        shared, b = self.start("shared", "shared", "sleep", "2", wait="0.01")
        exclusive, c = self.start("exclusive", "exclusive", "sleep", "2", wait="0.01")
        for process in (holder, shared, exclusive):
            self.finish(process)
        starts = [self.ready(marker)["time"] for marker in (a, b, c)]
        ends = [float(marker.with_suffix(".end").read_text()) for marker in (a, b, c)]
        self.assertLess(max(ends) - min(starts), 3.5)
        self.assertLess(max(starts), min(ends))

    def test_status_describes_live_holders_and_idle(self):
        self.assertEqual(self.status(), "idle\n")
        holder, h = self.start("shared", "descriptive")
        self.ready(h)
        other, o = self.start("exclusive", "compatible")
        self.ready(o)
        state = self.status()
        self.assertIn('holder: shared label="descriptive"', state)
        self.assertIn('holder: shared label="compatible"', state)
        self.assertEqual(len(state.splitlines()), 2)
        self.assertIn(f"pid={holder.pid}", state)
        self.assertIn("start=", state)
        self.assertIn(f"cwd={json.dumps(str(self.root))}", state)
        self.release(h)
        self.finish(holder)
        self.release(o)
        self.finish(other)
        self.assertEqual(self.status(), "idle\n")

    def test_exit_codes_and_signal_deaths_propagate(self):
        for code in (0, 23):
            with self.subTest(code=code):
                process, _ = self.start("shared", f"exit-{code}", "exit", str(code))
                self.finish(process, code)
        process, _ = self.start("exclusive", "death", "die", str(signal.SIGTERM))
        self.finish(process, 128 + signal.SIGTERM)
        self.assertEqual(self.status(), "idle\n")

    def test_signals_forward_and_record_stays_live_until_child_exits(self):
        for sig, action in ((s, a) for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
                            for a in ("signal", "group")):
            with self.subTest(signal=sig, action=action):
                process, marker = self.start("exclusive", f"{action}-{sig}", action)
                self.until(marker.with_suffix(".ready").exists)
                process.send_signal(sig)
                self.until(marker.with_suffix(".signal").exists)
                follower, _ = self.start("shared", f"parallel-{action}-{sig}", "exit", "0", wait="0.15")
                self.finish(follower)
                self.assertIsNone(process.poll(), "wrapper exited before the command")
                self.assertIn(f'holder: shared label="{action}-{sig}"', self.status())
                self.release(marker)
                self.finish(process, 128 + sig)
                self.assertEqual(marker.with_suffix(".signal").read_text(), str(sig))
                follower, _ = self.start("exclusive", f"after-{action}-{sig}", "exit", "0", wait="0.5")
                self.finish(follower)
                self.assertEqual(self.status(), "idle\n")

    def test_daemon_does_not_inherit_lock(self):
        for close_stdin in (False, True):
            with self.subTest(close_stdin=close_stdin):
                label = "parent-closed" if close_stdin else "parent-open"
                parent, marker = self.start("exclusive", label, "daemon", close_stdin=close_stdin)
                self.ready(marker)
                self.until(marker.with_suffix(".pid").exists)
                daemon_marker = marker.with_name(marker.name + "-daemon")
                daemon_pid = int(marker.with_suffix(".pid").read_text())
                try:
                    self.ready(daemon_marker)
                    # Keep the same inode visible after normal holder cleanup, so status
                    # detects an inherited record lock even though it cannot block runs.
                    # Closed stdin lets publish() allocate its CLOEXEC record as fd 0.
                    retained = self.directory / "holders" / "0"
                    retained.hardlink_to(self.directory / "holders" / str(parent.pid))
                    self.assertIn(f'holder: shared label="{label}"', self.status())
                    self.release(marker)
                    self.finish(parent)
                    os.kill(daemon_pid, 0)
                    self.assertIn(f'stale holder: shared label="{label}"', self.status())
                    retained.unlink()
                    follower, _ = self.start("exclusive", "after-daemon", "exit", "0", wait="0.5")
                    self.finish(follower)
                    self.assertEqual(self.status(), "idle\n")
                finally:
                    os.kill(daemon_pid, signal.SIGTERM)

    def test_dead_records_are_stale_and_do_not_block(self):
        process, marker = self.start("exclusive", "killed")
        self.ready(marker)
        child_pid = self.ready(marker)["pid"]
        process.kill()
        self.assertEqual(process.wait(timeout=3), -signal.SIGKILL)
        try:
            state = self.status()
            self.assertIn('stale holder: shared label="killed"', state)
            self.assertNotIn('\nholder:', "\n" + state)
            follower, _ = self.start("shared", "after-stale", "exit", "0", wait="0.5")
            self.finish(follower)
        finally:
            os.kill(child_pid, signal.SIGTERM)
            self.finish(process, -signal.SIGKILL)

    def test_record_of_a_reused_pid_is_stale(self):
        # A killed wrapper's pid can be reused by an unrelated live process.
        holders = self.directory / "holders"
        holders.mkdir(parents=True)
        (holders / str(os.getpid())).write_text(json.dumps({
            "mode": "shared", "label": "reused", "pid": os.getpid(),
            "start": datetime.now().isoformat(), "cwd": str(self.root)}))
        self.assertIn('stale holder: shared label="reused"', self.status())
        follower, _ = self.start("shared", "after-reuse", "exit", "0", wait="0.5")
        self.finish(follower)

    def test_lower_priority_only_lowers_and_survives_refusal(self):
        import importlib.util
        from unittest import mock
        spec = importlib.util.spec_from_file_location("cpu_lock_module", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for inherited, expected_call in ((0, 10), (10, None), (15, None)):
            with self.subTest(inherited=inherited), \
                    mock.patch.object(module.os, "getpriority", return_value=inherited), \
                    mock.patch.object(module.os, "setpriority") as setpriority:
                module.lower_priority()
                if expected_call is None:
                    setpriority.assert_not_called()
                else:
                    setpriority.assert_called_once_with(module.os.PRIO_PROCESS, 0, expected_call)
        for error in (PermissionError(1, "EPERM"), OSError(13, "EACCES")):
            with self.subTest(error=error), \
                    mock.patch.object(module.os, "getpriority", return_value=0), \
                    mock.patch.object(module.os, "setpriority", side_effect=error):
                module.lower_priority()  # must not raise: the command still runs

    def test_launch_applies_priority_and_utility_clamp(self):
        inherited = os.getpriority(os.PRIO_PROCESS, 0)
        # One step below the caller makes lowering observable; a caller already
        # at nice 19 has no headroom, so the child must simply keep 19.
        target = min(19, max(10, inherited + 1))
        command = [sys.executable, str(THIS), "worker", str(self.root / "priority"),
                   "launch-priority", str(target), str(self.directory)]
        if sys.platform == "darwin":
            reference = subprocess.run(
                ["/usr/sbin/taskpolicy", "-c", "utility", sys.executable, str(THIS),
                 "worker", str(self.root / "reference"), "priority"], env=self.environment,
                cwd=self.root, capture_output=True, text=True, check=True, timeout=30)
            utility = json.loads(reference.stdout)
            # A distinct starting clamp makes omitting the production utility
            # attribute observable even under a utility-clamped test runner.
            command = ["/usr/sbin/taskpolicy", "-c", "background", *command]
        result = subprocess.run(command, env=self.environment, cwd=self.root,
                                capture_output=True, text=True, check=True, timeout=30)
        before, child = map(json.loads, result.stdout.splitlines())
        print(f"launch priority: before={before}, child={child}", flush=True)
        self.assertEqual(before["nice"], inherited)
        self.assertEqual(child["nice"], target)
        if sys.platform == "darwin":
            self.assertLess(before["max_priority"], utility["max_priority"])
            self.assertEqual(child["max_priority"], utility["max_priority"])
        self.assertEqual(self.status(), "idle\n")

    def test_exec_errors_and_command_behavior_match_direct_exec(self):
        fixtures = (
            ("missing-interpreter", "#!/no-such-cpu-lock-interpreter\nprintf interpreted\\n\n",
             0o755, 127, errno.ENOENT, b""),
            ("invalid-format", "printf 'shell-interpreted\\n'\n",
             0o755, 126, errno.ENOEXEC, b""),
            ("not-executable", "#!/bin/sh\nprintf interpreted\\n\n",
             0o644, 126, errno.EACCES, b""),
            ("normal", "#!/bin/sh\nprintf '%s\\n' \"$1\"\n",
             0o755, 0, None, b"an argument with spaces\n"),
            ("exit-66", "#!/bin/sh\nprintf '%s\\n' \"$1\"\nexit 66\n",
             0o755, 66, None, b"an argument with spaces\n"),
        )
        cases = [("not-on-path", ["no-such-cpu-lock-command"], 127, errno.ENOENT, b"")]
        for name, source, mode, code, error, output in fixtures:
            path = self.root / name
            path.write_text(source)
            path.chmod(mode)
            # Exercise explicit paths and PATH lookup without shell fallback.
            for executable in (str(path), path.name):
                cases.append((name, [executable, "an argument with spaces"], code, error, output))
        environment = dict(self.environment, PATH=str(self.root))
        for name, command, code, error, output in cases:
            with self.subTest(command=command):
                try:
                    direct = subprocess.run(command, env=environment, cwd=self.root,
                                            capture_output=True)
                except OSError as failure:
                    self.assertEqual(failure.errno, error)
                    # exec has no child exit status on failure; use the shell's
                    # conventional 127 (not found) / 126 (cannot execute).
                    direct_code = 127 if failure.errno == errno.ENOENT else 126
                    direct_output = b""
                else:
                    self.assertIsNone(error)
                    direct_code, direct_output = direct.returncode, direct.stdout
                self.assertEqual((direct_code, direct_output), (code, output))
                wrapped = subprocess.run(self.cli("run", "--shared", "--label", name,
                                                  "--", *command), env=environment,
                                         cwd=self.root, capture_output=True)
                print(f"exec {command[0]}: direct={direct_code} cpu-lock={wrapped.returncode}",
                      flush=True)
                self.assertEqual((wrapped.returncode, wrapped.stdout), (direct_code, direct_output),
                                 wrapped.stderr)
                self.assertEqual(self.status(), "idle\n")

    def test_nested_modes_export_shared_identity(self):
        for outer, inner in (("shared", "shared"), ("exclusive", "exclusive"),
                             ("exclusive", "shared"), ("shared", "exclusive")):
            with self.subTest(outer=outer, inner=inner):
                marker = self.root / "nested"
                marker.unlink(missing_ok=True)
                nested = self.cli("run", "--" + inner, "--wait", "0.2", "--label", "inner", "--",
                                  sys.executable, str(THIS), "worker", str(marker), "exit", "0")
                process, _ = self.start(outer, "outer", command=nested)
                self.finish(process)
                state = self.ready(marker)
                self.assertEqual(state["held"], "shared")
                self.assertEqual(state["directory"], str(self.directory))
                self.assertEqual(self.status(), "idle\n")

    def test_usage_errors_are_two(self):
        valid = ["run", "--shared", "--wait", "0.1", "--label", "usage"]
        invalid = [
            [], ["run"], valid, valid + ["--"],
            ["run", "--wait", "1", "--label", "usage", "--", "unused"],
            valid + ["--exclusive", "--", "unused"],
            ["run", "--shared", "--wait", "1", "--", "unused"],
            ["run", "--shared", "--wait", "1", "--label", "", "--", "unused"],
        ]
        invalid.extend(["run", "--shared", "--wait", value, "--label", "usage", "--", "unused"]
                       for value in ("0", "-1", "nan", "inf", "-inf", "nope"))
        for args in invalid:
            with self.subTest(args=args):
                result = subprocess.run(self.cli(*args), env=self.environment,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stderr)


if __name__ == "__main__":
    if sys.argv[1:2] == ["worker"]:
        worker()
    else:
        unittest.main(verbosity=2)
