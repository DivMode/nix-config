"""Exercise the generated installer with temporary files and builder ownership."""

import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile


installer, desired_file, bash = sys.argv[1:]
source = Path(installer).read_text()
desired = Path(desired_file).read_bytes()
expected_hash = hashlib.sha256(desired).hexdigest()
old = b"previous managed generation\n"
old_hash = hashlib.sha256(old).hexdigest()
directory = "/Library/Application Support/ClaudeCode"
assert directory in source, "installer target must be redirected before execution"

with tempfile.TemporaryDirectory(prefix="agent-policy-test-") as scratch:
    for case in ["stale-receipt", "missing-receipt", "foreign-policy", "owned-upgrade"]:
        target = Path(scratch) / case
        target.mkdir()
        policy = target / "managed-settings.json"
        receipt = target / ".nix-config-managed-settings.sha256"
        policy.write_bytes(old if case == "owned-upgrade" else
                           b"foreign policy\n" if case == "foreign-policy" else desired)
        if case != "missing-receipt":
            receipt.write_text(old_hash + "\n")
        before_bytes, before_mtime = policy.read_bytes(), policy.stat().st_mtime_ns

        # Only redirect the privileged destination and ownership. Hashing,
        # collision guards, permissions, receipt writes and renames are the
        # actual generated installer, exercised on real files without root.
        script = source.replace(directory, str(target))
        script = script.replace("root:wheel", f"{os.geteuid()}:{os.getegid()}")
        script = script.replace("-o root -g wheel", f"-o {os.geteuid()} -g {os.getegid()}")
        assert directory not in script
        program = Path(scratch) / "install-policy.sh"
        program.write_text(script)
        result = subprocess.run([bash, str(program)], capture_output=True, text=True, timeout=5)
        if case == "foreign-policy":
            assert result.returncode != 0, "foreign policy was accepted"
            assert "changed outside nix-config" in result.stderr, result.stderr
            assert policy.read_bytes() == before_bytes
            assert receipt.read_text() == old_hash + "\n"
        else:
            assert result.returncode == 0, result.stderr
            assert policy.read_bytes() == desired
            assert receipt.read_text() == expected_hash + "\n"
            assert policy.stat().st_mode & 0o777 == 0o644
            assert receipt.stat().st_mode & 0o777 == 0o644
            assert target.stat().st_mode & 0o777 == 0o755
            if case != "owned-upgrade":
                assert policy.stat().st_mtime_ns == before_mtime, "recovery rewrote current policy"
        print(f"PASS managed policy installer: {case}", flush=True)
