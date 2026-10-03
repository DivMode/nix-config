"""Protect key-free local access, provider persistence, and collision refusal."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

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
            "management": {"allow-remote": False, "secret-key": ""},
            "access": {"api-keys": []},
            "oauth": {"providers": {"aistudio": {"ws-auth": False}}},
        }

    def prepare(self):
        state_module.prepare(self.state, self.desired)

    def test_private_stable_configuration_without_key_generation(self):
        self.prepare()
        config = self.state / "gateway" / "config.yaml"
        for path in (self.state, config):
            self.assertEqual(path.stat().st_mode & 0o077, 0)
        before = (config.read_bytes(), config.stat().st_mtime_ns)
        self.prepare()
        self.assertEqual(before, (config.read_bytes(), config.stat().st_mtime_ns))
        self.assertFalse((self.state / "keys").exists())
        gateway = yaml.safe_load(config.read_text())
        self.assertEqual(gateway["management"]["secret-key"], "")
        self.assertEqual(gateway["access"]["api-keys"], [])

    def test_existing_auth_is_removed_while_providers_and_history_are_preserved(self):
        self.prepare()
        config = self.state / "gateway" / "config.yaml"
        current = yaml.safe_load(config.read_text())
        providers = [{"api-key": "test-provider-key", "base-url": "https://example.invalid"}]
        current["claude-api-key"] = providers
        current["server"]["host"] = "0.0.0.0"
        current["management"].update({"allow-remote": True, "secret-key": "previous-hash"})
        current["access"]["api-keys"] = ["previous-client-key"]
        current["oauth"]["providers"]["aistudio"]["ws-auth"] = True
        config.write_text(yaml.safe_dump(current))
        history = self.state / "manager" / "history"
        history.write_bytes(b"preserve application data")
        self.prepare()
        actual = yaml.safe_load(config.read_text())
        self.assertEqual(actual["claude-api-key"], providers)
        self.assertEqual(actual["access"]["api-keys"], [])
        self.assertEqual(actual["management"]["secret-key"], "")
        self.assertFalse(actual["oauth"]["providers"]["aistudio"]["ws-auth"])
        self.assertEqual(actual["server"]["host"], "127.0.0.1")
        self.assertFalse(actual["management"]["allow-remote"])
        self.assertEqual(history.read_bytes(), b"preserve application data")

    def test_unmanaged_deployment_and_config_symlink_are_not_overwritten(self):
        self.state.mkdir(mode=0o700)
        sentinel = self.state / "existing-config"
        sentinel.write_text("keep this")
        with self.assertRaisesRegex(ValueError, "unmanaged"):
            self.prepare()
        self.assertEqual(sentinel.read_text(), "keep this")
        sentinel.unlink()
        self.prepare()
        config = self.state / "gateway" / "config.yaml"
        config.unlink()
        target = Path(self.temporary.name) / "unrelated-config"
        target.write_text("do not change")
        config.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "non-regular"):
            self.prepare()
        self.assertEqual(target.read_text(), "do not change")


if __name__ == "__main__":
    unittest.main()
