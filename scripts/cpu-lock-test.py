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
    if action == "hold":
        limit = time.monotonic() + 60
        while not marker.with_suffix(".release").exists():
            if time.monotonic() > limit:
                sys.exit(99)
            time.sleep(0.01)
    elif action == "sleep":
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
                                   str(marker.with_suffix(".daemon")), "hold"],
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, close_fds=False)
        marker.with_suffix(".pid").write_text(str(daemon.pid))
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

    def start(self, mode, label, action="hold", *extra, wait="30", command=None):
        marker = self.root / label
        command = command or [sys.executable, str(THIS), "worker", str(marker), action, *extra]
        process = subprocess.Popen(self.cli("run", "--" + mode, "--wait", wait,
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

    def queued(self, label):
        observed = []

        def waiting():
            for path in (self.directory / "waiting").glob("*"):
                if path.name.isdecimal():
                    record = json.loads(path.read_text())
                    if record["label"] == label:
                        observed.append(record)
                        return True
            return False

        # Synchronize on the atomically published record, without charging
        # status interpreter startup against a deliberately short wait budget.
        self.until(waiting)
        return observed[0]

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

    def test_writer_waits_for_every_reader_and_excludes_both_modes(self):
        first, a = self.start("shared", "first")
        second, b = self.start("shared", "second")
        self.ready(a)
        self.ready(b)
        writer, w = self.start("exclusive", "writer")
        self.queued("writer")
        self.release(a)
        self.finish(first)
        time.sleep(0.15)
        self.assertFalse(w.exists(), "writer entered while second reader was running")
        self.release(b)
        self.finish(second)
        self.ready(w)
        other, o = self.start("exclusive", "other")
        self.queued("other")
        reader, r = self.start("shared", "reader")
        time.sleep(0.15)
        self.assertFalse(r.exists())
        self.assertFalse(o.exists())
        self.release(w)
        self.finish(writer)
        self.ready(o)
        self.assertFalse(r.exists())
        self.release(o)
        self.finish(other)
        self.ready(r)
        self.release(r)
        self.finish(reader)

    def test_announced_writer_precedes_later_readers(self):
        holder, h = self.start("shared", "holder")
        self.ready(h)
        writer, w = self.start("exclusive", "writer")
        self.queued("writer")
        reader, r = self.start("shared", "late-reader")
        time.sleep(0.15)
        self.assertFalse(r.exists())
        self.release(h)
        self.finish(holder)
        self.ready(w)
        self.assertFalse(r.exists())
        self.release(w)
        self.finish(writer)
        self.ready(r)
        self.assertGreater(self.ready(r)["time"], float(w.with_suffix(".end").read_text()))
        self.release(r)
        self.finish(reader)

    def test_deadline_spans_turnstile_and_main_and_reports_once(self):
        holder, h = self.start("exclusive", "initial")
        self.ready(h)
        reader, r = self.start("shared", "reader")
        # Seeing this diagnostic proves the reader has the turnstile and is
        # blocked on main; a following writer must spend its budget on both.
        self.assertIn("waiting on", reader.stderr.readline())
        writer, w = self.start("exclusive", "timeout", wait="2")
        queued = self.queued("timeout")
        started = datetime.fromisoformat(queued["start"]).timestamp()
        time.sleep(1.2)
        self.release(h)
        self.finish(holder)
        _, err = self.finish(writer, 75)
        elapsed = time.time() - started
        self.assertGreaterEqual(elapsed, 2)
        self.assertLess(elapsed, 2.5, "wait budget restarted after the turnstile")
        self.assertEqual(err.count("cpu-lock: waiting on"), 1)
        self.assertIn('label="initial"', err.splitlines()[0])
        self.assertIn('label="reader"', err.splitlines()[-1])
        self.assertIn(f"pid={reader.pid}", err)
        self.assertIn(f"cwd={json.dumps(str(self.root))}", err)
        self.assertFalse(w.exists())
        self.assertNotIn('label="timeout"', self.status())
        self.ready(r)
        self.release(r)
        self.finish(reader)

    def test_status_describes_live_holders_waiters_and_idle(self):
        self.assertEqual(self.status(), "idle\n")
        holder, h = self.start("shared", "descriptive")
        self.ready(h)
        writer, w = self.start("exclusive", "queued")
        self.queued("queued")
        state = self.status()
        self.assertIn('holder: shared label="descriptive"', state)
        self.assertIn('exclusive waiter: exclusive label="queued"', state)
        self.assertIn(f"pid={holder.pid}", state)
        self.assertIn("start=", state)
        self.assertIn(f"cwd={json.dumps(str(self.root))}", state)
        self.release(h)
        self.finish(holder)
        self.ready(w)
        self.release(w)
        self.finish(writer)
        self.assertEqual(self.status(), "idle\n")

    def test_exit_codes_and_signal_deaths_propagate(self):
        for code in (0, 23):
            with self.subTest(code=code):
                process, _ = self.start("shared", f"exit-{code}", "exit", str(code))
                self.finish(process, code)
        process, _ = self.start("exclusive", "death", "die", str(signal.SIGTERM))
        self.finish(process, 128 + signal.SIGTERM)
        self.assertEqual(self.status(), "idle\n")

    def test_signals_forward_and_lock_stays_until_child_exits(self):
        for sig, action in ((s, a) for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
                            for a in ("signal", "group")):
            with self.subTest(signal=sig, action=action):
                process, marker = self.start("exclusive", f"{action}-{sig}", action)
                self.until(marker.with_suffix(".ready").exists)
                process.send_signal(sig)
                self.until(marker.with_suffix(".signal").exists)
                blocked, _ = self.start("shared", f"blocked-{action}-{sig}", "exit", "0", wait="0.15")
                self.finish(blocked, 75)
                self.assertIsNone(process.poll(), "wrapper exited before the command")
                self.release(marker)
                self.finish(process, 128 + sig)
                self.assertEqual(marker.with_suffix(".signal").read_text(), str(sig))
                follower, _ = self.start("exclusive", f"after-{action}-{sig}", "exit", "0", wait="0.5")
                self.finish(follower)
                self.assertEqual(self.status(), "idle\n")

    def test_interrupted_waiter_removes_writer_preference(self):
        holder, h = self.start("shared", "holder")
        self.ready(h)
        writer, _ = self.start("exclusive", "cancelled")
        self.queued("cancelled")
        writer.terminate()
        self.finish(writer, 128 + signal.SIGTERM)
        reader, _ = self.start("shared", "after-cancel", "exit", "0", wait="0.5")
        self.finish(reader)
        self.release(h)
        self.finish(holder)

    def test_daemon_does_not_inherit_lock(self):
        parent, marker = self.start("exclusive", "parent", "daemon")
        self.finish(parent)
        daemon_marker = marker.with_suffix(".daemon")
        daemon_pid = int(marker.with_suffix(".pid").read_text())
        try:
            self.ready(daemon_marker)
            os.kill(daemon_pid, 0)
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
            self.assertIn('stale holder: exclusive label="killed"', state)
            self.assertNotIn('\nholder:', "\n" + state)
            # Also leave a genuine stale writer record, by killing a waiter.
            holder, h = self.start("shared", "live")
            self.ready(h)
            waiter, _ = self.start("exclusive", "dead-waiter")
            self.queued("dead-waiter")
            waiter.kill()
            self.finish(waiter, -signal.SIGKILL)
            self.assertIn("stale exclusive waiter:", self.status())
            follower, _ = self.start("shared", "after-stale", "exit", "0", wait="0.5")
            self.finish(follower)
            self.release(h)
            self.finish(holder)
        finally:
            os.kill(child_pid, signal.SIGTERM)
            self.finish(process, -signal.SIGKILL)

    def test_record_of_a_reused_pid_is_stale(self):
        # A killed waiter's pid can be reused by an unrelated long-lived process.
        waiting = self.directory / "waiting"
        waiting.mkdir(parents=True)
        (waiting / str(os.getpid())).write_text(json.dumps({
            "mode": "exclusive", "label": "reused", "pid": os.getpid(),
            "start": datetime.now().isoformat(), "cwd": str(self.root)}))
        self.assertIn('stale exclusive waiter: exclusive label="reused"', self.status())
        follower, _ = self.start("shared", "after-reuse", "exit", "0", wait="0.5")
        self.finish(follower)

    def test_nested_modes_export_identity_and_refuse_upgrade(self):
        for outer, inner, expected in (("shared", "shared", 0),
                                        ("exclusive", "exclusive", 0),
                                        ("exclusive", "shared", 0),
                                        ("shared", "exclusive", 2)):
            with self.subTest(outer=outer, inner=inner):
                marker = self.root / "nested"
                marker.unlink(missing_ok=True)
                nested = self.cli("run", "--" + inner, "--wait", "0.2", "--label", "inner", "--",
                                  sys.executable, str(THIS), "worker", str(marker), "exit", "0")
                process, _ = self.start(outer, "outer", command=nested)
                _, err = self.finish(process, expected)
                if expected:
                    self.assertIn("would wait on itself", err)
                    self.assertFalse(marker.exists())
                else:
                    state = self.ready(marker)
                    self.assertEqual(state["held"], outer)
                    self.assertEqual(state["directory"], str(self.directory))
                self.assertEqual(self.status(), "idle\n")

    def test_usage_errors_are_two(self):
        valid = ["run", "--shared", "--wait", "0.1", "--label", "usage"]
        invalid = [
            [], ["run"], valid, valid + ["--"],
            ["run", "--wait", "1", "--label", "usage", "--", "unused"],
            valid + ["--exclusive", "--", "unused"],
            ["run", "--shared", "--label", "usage", "--", "unused"],
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
