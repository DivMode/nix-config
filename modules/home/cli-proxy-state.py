"""Reconcile only the gateway's declared boundary; preserve provider state."""

import json
import os
from pathlib import Path
import stat
import sys
import tempfile

import yaml


def owned(path, directory=False):
    info = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError(f"Refusing unowned or non-regular path: {path}")
    if info.st_mode & 0o077:
        raise ValueError(f"Private state has group/other permissions: {path}")


def write_changed(path, content):
    if path.exists() or path.is_symlink():
        owned(path)
        if path.read_text() == content:
            return
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=".prepare-")
    try:
        with os.fdopen(descriptor, "w") as output:
            output.write(content)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def merge(current, desired):
    for key, value in desired.items():
        if isinstance(value, dict):
            child = current.setdefault(key, {})
            if not isinstance(child, dict):
                raise ValueError(f"Expected a configuration object at {key}")
            merge(child, value)
        else:
            current[key] = value


def prepare(state, desired):
    os.umask(0o077)
    marker = state / ".nix-managed"
    if state.exists() or state.is_symlink():
        owned(state, directory=True)
        if not marker.exists() and any(state.iterdir()):
            raise ValueError("Refusing to adopt an existing unmanaged deployment")
    else:
        state.mkdir(parents=True, mode=0o700)
    initialized = marker.exists()
    if initialized:
        owned(marker)
        if marker.read_text() != "cli-proxy-state-v1\n":
            raise ValueError("Unrecognized deployment marker")

    for name in ("gateway", "auth", "plugins", "manager", "logs"):
        path = state / name
        if not path.exists() and not path.is_symlink():
            path.mkdir(mode=0o700)
        owned(path, directory=True)

    path = state / "gateway" / "config.yaml"
    current = {}
    if path.exists() or path.is_symlink():
        owned(path)
        current = yaml.safe_load(path.read_text())
        if not isinstance(current, dict):
            raise ValueError("Gateway config must be a YAML object")
    elif initialized:
        raise ValueError("Gateway config is missing; restore it before rebuilding")

    # CPA v8 gives canonical fields precedence over legacy spellings. Use the
    # canonical layout so old UI writes cannot override the declared listener.
    merge(current, desired)
    write_changed(path, yaml.safe_dump(current, sort_keys=False))
    write_changed(marker, "cli-proxy-state-v1\n")


if __name__ == "__main__":
    try:
        prepare(Path(sys.argv[1]), json.loads(Path(sys.argv[2]).read_text()))
    except (OSError, ValueError, yaml.YAMLError) as error:
        # Do not print parsed YAML or secret content on a failure.
        message = str(error) if not isinstance(error, yaml.YAMLError) else "Invalid gateway YAML"
        print(f"CLIProxyAPI state preparation failed: {message}", file=sys.stderr)
        raise SystemExit(1)
