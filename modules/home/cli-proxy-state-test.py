"""Protect credential persistence, mutable providers, and collision refusal."""

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

import bcrypt
import yaml

spec = importlib.util.spec_from_file_location("cli_proxy_state", Path(__file__).with_name("cli-proxy-state.py"))
state_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state_module)


class StateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name) / "deployment"
        self.desired = {
            "config-version": 8,
            "server": {"host": "127.0.0.1", "port": 8317},
            "management": {"allow-remote": False},
        }

    def prepare(self):
        state_module.prepare(self.state, self.desired)

    def test_credentials_are_private_stable_and_never_recreated(self):
        self.prepare()
        keys = {path.name: path.read_bytes() for path in (self.state / "keys").iterdir()}
        for path in (self.state, self.state / "keys", self.state / "keys" / "admin"):
            self.assertEqual(path.stat().st_mode & 0o077, 0)
        config = self.state / "gateway" / "config.yaml"
        before = (config.read_bytes(), config.stat().st_mtime_ns)
        self.prepare()
        self.assertEqual(before, (config.read_bytes(), config.stat().st_mtime_ns))
        self.assertEqual(keys, {path.name: path.read_bytes() for path in (self.state / "keys").iterdir()})
        gateway = yaml.safe_load(config.read_text())
        self.assertTrue(bcrypt.checkpw(keys["management"].strip(), gateway["management"]["secret-key"].encode()))
        self.assertIn(keys["client"].decode().strip(), gateway["access"]["api-keys"])
        (self.state / "keys" / "admin").unlink()
        with self.assertRaisesRegex(ValueError, "restore it"):
            self.prepare()
        self.assertFalse((self.state / "keys" / "admin").exists())

    def test_rebuild_preserves_providers_and_reasserts_local_boundary(self):
        self.prepare()
        config = self.state / "gateway" / "config.yaml"
        current = yaml.safe_load(config.read_text())
        providers = [{"api-key": "test-provider-key", "base-url": "https://example.invalid"}]
        current["claude-api-key"] = providers
        current["server"]["host"] = "0.0.0.0"
        current["management"]["allow-remote"] = True
        current["access"]["api-keys"].append("additional-client-key")
        config.write_text(yaml.safe_dump(current))
        self.prepare()
        actual = yaml.safe_load(config.read_text())
        self.assertEqual(actual["claude-api-key"], providers)
        self.assertIn("additional-client-key", actual["access"]["api-keys"])
        self.assertEqual(actual["server"]["host"], "127.0.0.1")
        self.assertFalse(actual["management"]["allow-remote"])

    def test_unmanaged_deployment_and_symlink_are_not_overwritten(self):
        self.state.mkdir(mode=0o700)
        sentinel = self.state / "existing-config"
        sentinel.write_text("keep this")
        with self.assertRaisesRegex(ValueError, "unmanaged"):
            self.prepare()
        self.assertEqual(sentinel.read_text(), "keep this")
        sentinel.unlink()
        self.prepare()
        key = self.state / "keys" / "client"
        key.unlink()
        target = Path(self.temporary.name) / "unrelated-key"
        target.write_text("do not change")
        key.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "non-regular"):
            self.prepare()
        self.assertEqual(target.read_text(), "do not change")


if __name__ == "__main__":
    unittest.main()
