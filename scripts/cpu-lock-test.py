"""Exercise the real CLI and kernel locks with independent concurrent processes."""

from datetime import datetime
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
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
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

    def start(self, mode, label, action="hold", *extra, wait=None, command=None):
        marker = self.root / label
        command = command or [sys.executable, str(THIS), "worker", str(marker), action, *extra]
        wait_args = [] if wait is None else ["--wait", wait]
        process = subprocess.Popen(self.cli("run", "--" + mode, *wait_args,
                                           "--label", label, "--", *command),
                                   env=self.environment, cwd=self.root, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
        parent, marker = self.start("exclusive", "parent", "daemon")
        self.ready(marker)
        self.until(marker.with_suffix(".pid").exists)
        daemon_marker = marker.with_name(marker.name + "-daemon")
        daemon_pid = int(marker.with_suffix(".pid").read_text())
        try:
            self.ready(daemon_marker)
            # Keep the same inode visible after normal holder cleanup, so status
            # detects an inherited record lock even though it cannot block runs.
            retained = self.directory / "holders" / "0"
            retained.hardlink_to(self.directory / "holders" / str(parent.pid))
            self.assertIn('holder: shared label="parent"', self.status())
            self.release(marker)
            self.finish(parent)
            os.kill(daemon_pid, 0)
            self.assertIn('stale holder: shared label="parent"', self.status())
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
