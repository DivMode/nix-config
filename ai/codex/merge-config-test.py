#!/usr/bin/env python3

from __future__ import annotations

import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import tomllib
import unittest


MERGER = Path(sys.argv.pop(1))
DECLARED = Path(sys.argv.pop(1))


class MergeCodexConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.config = self.directory / "config.toml"

    def run_merger(self, *, check: bool = True) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [str(MERGER), "--declared", str(DECLARED), str(self.config)],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if check and result.returncode != 0:
            self.fail(f"merger failed: {result.stderr.strip()}")
        return result

    def assert_managed_values(self, parsed: dict[str, object]) -> None:
        self.assertEqual(parsed["approval_policy"], "never")
        self.assertEqual(parsed["model_reasoning_effort"], "xhigh")
        self.assertEqual(parsed["approvals_reviewer"], "auto_review")
        self.assertEqual(parsed["sandbox_mode"], "danger-full-access")
        defaults = parsed["apps"]["_default"]  # type: ignore[index]
        self.assertEqual(defaults["approvals_reviewer"], "auto_review")
        self.assertEqual(defaults["default_tools_approval_mode"], "approve")
        self.assertEqual(defaults["destructive_enabled"], True)
        self.assertEqual(defaults["enabled"], True)
        self.assertEqual(defaults["open_world_enabled"], True)

    def test_preserves_comments_unknown_tables_and_order(self) -> None:
        original = '''# user-level comment
model = "example-model"
approval_policy = "on-request" # approval comment

[marketplaces.example]
source = "https://example.invalid/marketplace"

[plugins."example@marketplace"]
enabled = true

[projects."/example/source-checkout"]
trust_level = "trusted"

[mcp_servers.example]
command = "/Applications/Example.app/Contents/MacOS/example"

[unknown]
answer = 42 # unknown comment

[apps.example]
enabled = false
'''
        self.config.write_text(original, encoding="utf-8")

        self.run_merger()
        merged = self.config.read_text(encoding="utf-8")
        parsed = tomllib.loads(merged)

        self.assert_managed_values(parsed)
        self.assertEqual(parsed["model"], "example-model")
        self.assertEqual(parsed["plugins"]["example@marketplace"]["enabled"], True)
        self.assertEqual(parsed["projects"]["/example/source-checkout"]["trust_level"], "trusted")
        self.assertEqual(parsed["mcp_servers"]["example"]["command"], "/Applications/Example.app/Contents/MacOS/example")
        self.assertEqual(parsed["unknown"]["answer"], 42)
        self.assertEqual(parsed["apps"]["example"]["enabled"], False)
        self.assertIn("# user-level comment", merged)
        self.assertIn("# approval comment", merged)
        self.assertIn("# unknown comment", merged)

        existing_headers = [
            "[marketplaces.example]",
            '[plugins."example@marketplace"]',
            '[projects."/example/source-checkout"]',
            "[mcp_servers.example]",
            "[unknown]",
            "[apps.example]",
        ]
        positions = [merged.index(header) for header in existing_headers]
        self.assertEqual(positions, sorted(positions))

    def test_inserts_and_updates_managed_values(self) -> None:
        self.config.write_text(
            '''sandbox_mode = "read-only"

[apps._default]
enabled = false # app comment
custom = "preserve"
''',
            encoding="utf-8",
        )

        self.run_merger()
        merged = self.config.read_text(encoding="utf-8")
        parsed = tomllib.loads(merged)

        self.assert_managed_values(parsed)
        self.assertEqual(parsed["apps"]["_default"]["custom"], "preserve")
        self.assertIn("# app comment", merged)

    def test_second_run_is_byte_and_mtime_idempotent(self) -> None:
        self.config.write_text('model = "example-model"\n', encoding="utf-8")
        self.run_merger()
        first_content = self.config.read_bytes()
        first_stat = self.config.stat()

        result = self.run_merger()

        self.assertEqual(result.stdout.strip(), "unchanged")
        self.assertEqual(self.config.read_bytes(), first_content)
        self.assertEqual(self.config.stat().st_mtime_ns, first_stat.st_mtime_ns)

    def test_atomic_replacement_and_mode_0600(self) -> None:
        self.config.write_text('approval_policy = "on-request"\n', encoding="utf-8")
        os.chmod(self.config, 0o644)
        original_inode = self.config.stat().st_ino

        self.run_merger()

        self.assertNotEqual(self.config.stat().st_ino, original_inode)
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)
        self.assertEqual(list(self.directory.glob(".config.toml.*.tmp")), [])

    def test_unchanged_content_only_repairs_mode(self) -> None:
        declared_content = DECLARED.read_text(encoding="utf-8")
        self.config.write_text(declared_content, encoding="utf-8")
        os.chmod(self.config, 0o644)
        original_stat = self.config.stat()

        result = self.run_merger()

        self.assertEqual(result.stdout.strip(), "unchanged")
        self.assertEqual(self.config.read_text(encoding="utf-8"), declared_content)
        self.assertEqual(self.config.stat().st_mtime_ns, original_stat.st_mtime_ns)
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)

    def test_invalid_toml_fails_without_overwrite(self) -> None:
        invalid = b"this is not = valid TOML\n"
        self.config.write_bytes(invalid)
        os.chmod(self.config, 0o640)
        original_stat = self.config.stat()

        result = self.run_merger(check=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid TOML", result.stderr)
        self.assertEqual(self.config.read_bytes(), invalid)
        final_stat = self.config.stat()
        self.assertEqual(final_stat.st_mtime_ns, original_stat.st_mtime_ns)
        self.assertEqual(stat.S_IMODE(final_stat.st_mode), 0o640)
        self.assertEqual(list(self.directory.iterdir()), [self.config])


if __name__ == "__main__":
    unittest.main()
