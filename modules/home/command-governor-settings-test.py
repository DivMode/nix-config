#!/usr/bin/env python3
"""Verify the activation writer with disposable settings, never real app state.

Two boundaries are protected here, and nothing else:

  * Prime Agent owns ~/.prime/agent/settings.json at runtime. A writer that
    truncates, widens, or replaces state the application wrote is a data-loss
    bug that only shows up as a lost login or a lost model choice, long after
    the activation that caused it.
  * The package list is Command Governor's, read from its checkout at
    activation time. Its two vendored entries are relative to a PROJECT's
    .prime/agent/, so installing the same file globally without rewriting them
    points Prime at ~/pins/... and silently loads nothing -- no error, just a
    harness that is quietly absent.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

WRITER = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else (
    Path(__file__).resolve().parent / "command-governor-settings.sh"
)
JQ = sys.argv[2] if len(sys.argv) > 2 else shutil.which("jq")

HARNESS_PACKAGES = [
    "npm:pi-tasks@0.2.5",
    "../../pins/packages/pi-gpt-0.4.3",
]


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

        self.checkout = self.root / "commandgovernor"
        self.harness = self.checkout / "harness" / "settings.project.json"
        self.harness.parent.mkdir(parents=True)
        self.write_harness(HARNESS_PACKAGES)

        self.directory = self.root / "agent"
        self.directory.mkdir()
        self.settings = self.directory / "settings.json"

        self.assertIsNotNone(JQ)

    def write_harness(self, packages):
        self.harness.write_text(json.dumps({"$comment": ["ignored"], "packages": packages}))

    @property
    def expected(self):
        return [
            "npm:pi-tasks@0.2.5",
            f"{self.checkout}/pins/packages/pi-gpt-0.4.3",
        ]

    def write(self, jq=None, env=None):
        return subprocess.run(
            ["bash", str(WRITER), jq or JQ, str(self.checkout), str(self.directory)],
            capture_output=True,
            text=True,
            env=env,
        )

    # --- the package list, read from the checkout and made global ------------

    def test_relative_entries_become_absolute_and_npm_entries_are_untouched(self):
        self.assertEqual(self.write().returncode, 0)
        self.assertEqual(json.loads(self.settings.read_text())["packages"], self.expected)

    def test_unresolvable_package_spelling_fails_loudly(self):
        for entry in ("./local", "/absolute/path", "github:owner/repo", "../sibling"):
            with self.subTest(entry=entry):
                self.write_harness([entry])
                result = self.write()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(entry, result.stderr)
                self.assertFalse(self.settings.exists())

    def test_missing_checkout_file_fails_and_names_the_path(self):
        self.harness.unlink()
        result = self.write()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(self.harness), result.stderr)
        self.assertFalse(self.settings.exists())

    def test_malformed_checkout_file_fails_without_writing(self):
        for content in ("{broken", "[]", '{"packages": "not-a-list"}'):
            with self.subTest(content=content):
                self.harness.write_text(content)
                self.assertNotEqual(self.write().returncode, 0)
                self.assertFalse(self.settings.exists())

    # --- Prime's own state ---------------------------------------------------

    def test_absent_settings_are_created_private(self):
        self.assertEqual(self.write().returncode, 0)
        self.assertEqual(json.loads(self.settings.read_text()), {"packages": self.expected})
        self.assertEqual(self.settings.stat().st_mode & 0o777, 0o600)

    def test_application_state_survives_declared_package_update(self):
        self.settings.write_text(
            json.dumps({"packages": ["old"], "recentModel": "model-a", "localState": {"keep": True}})
        )
        self.assertEqual(self.write().returncode, 0)
        self.assertEqual(
            json.loads(self.settings.read_text()),
            {"packages": self.expected, "recentModel": "model-a", "localState": {"keep": True}},
        )

    def test_invalid_existing_state_is_preserved(self):
        for content in ("{broken", "[]", "null", "42"):
            with self.subTest(content=content):
                self.settings.write_text(content)
                self.assertNotEqual(self.write().returncode, 0)
                self.assertEqual(self.settings.read_text(), content)
                self.assertFalse((self.directory / ".nix-config-settings.lock").exists())

    def test_symlink_and_its_target_are_preserved(self):
        target = self.root / "user-owned.json"
        target.write_text('{"keep":true}')
        self.settings.symlink_to(target)
        self.assertNotEqual(self.write().returncode, 0)
        self.assertTrue(self.settings.is_symlink())
        self.assertEqual(target.read_text(), '{"keep":true}')

    def test_unchanged_content_is_not_rewritten_but_mode_is_private(self):
        content = json.dumps({"packages": self.expected}, indent=1) + "\n"
        self.settings.write_text(content)
        self.settings.chmod(0o644)
        before = self.settings.stat().st_mtime_ns
        self.assertEqual(self.write().returncode, 0)
        self.assertEqual(self.settings.read_text(), content)
        self.assertEqual(self.settings.stat().st_mtime_ns, before)
        self.assertEqual(self.settings.stat().st_mode & 0o777, 0o600)

    def test_existing_activation_lock_is_not_removed(self):
        lock = self.directory / ".nix-config-settings.lock"
        lock.mkdir()
        self.assertNotEqual(self.write().returncode, 0)
        self.assertTrue(lock.is_dir())
        self.assertFalse(self.settings.exists())

    def test_detected_concurrent_application_edit_is_preserved(self):
        # Prime writes this file while the machine is being rebuilt. The proxy
        # fires on the merge call -- the only one passing --argjson -- so the
        # application edit lands after the writer has read the file and before
        # it commits, which is the window the re-read exists to catch.
        self.settings.write_text('{"recentModel":"model-a"}')
        proxy = self.root / "jq-proxy.sh"
        proxy.write_text(
            '#!/usr/bin/env bash\n'
            'if [[ " $* " == *" --argjson "* ]]; then\n'
            '  printf \'{"recentModel":"model-b"}\' > "$SETTINGS_TEST_PATH"\n'
            'fi\n'
            'exec "$SETTINGS_TEST_JQ" "$@"\n'
        )
        proxy.chmod(0o700)
        env = dict(os.environ, SETTINGS_TEST_PATH=str(self.settings), SETTINGS_TEST_JQ=JQ)
        self.assertNotEqual(self.write(str(proxy), env).returncode, 0)
        self.assertEqual(json.loads(self.settings.read_text()), {"recentModel": "model-b"})
        self.assertEqual(list(self.directory.glob(".settings.nix-config.*")), [])


if __name__ == "__main__":
    unittest.main(argv=sys.argv[:1])
