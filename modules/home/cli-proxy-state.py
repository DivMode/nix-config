"""Reconcile only the gateway's declared boundary; preserve provider state."""

import json
import os
from pathlib import Path
import secrets
import stat
import sys
import tempfile

import bcrypt
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

    for name in ("keys", "gateway", "auth", "plugins", "manager", "logs"):
        path = state / name
        if not path.exists() and not path.is_symlink():
            path.mkdir(mode=0o700)
        owned(path, directory=True)

    keys = {}
    for name in ("management", "admin", "client"):
        path = state / "keys" / name
        if not path.exists() and not path.is_symlink():
            if initialized:
                raise ValueError(f"Missing {name} key; restore it instead of rotating credentials")
            # Exclusive creation never overwrites credentials.
            with path.open("x") as output:
                output.write(secrets.token_urlsafe(32) + "\n")
        owned(path)
        value = path.read_text().strip()
        if len(value) < 32 or any(c.isspace() for c in value):
            raise ValueError(f"Invalid {name} key file")
        keys[name] = value

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
    management = current["management"]
    existing_hash = management.get("secret-key", "")
    valid_hash = False
    if isinstance(existing_hash, str) and existing_hash.startswith(("$2a$", "$2b$", "$2y$")):
        try:
            valid_hash = bcrypt.checkpw(keys["management"].encode(), existing_hash.encode())
        except ValueError:
            pass
    if not valid_hash:
        management["secret-key"] = bcrypt.hashpw(keys["management"].encode(), bcrypt.gensalt()).decode()
    access = current.setdefault("access", {})
    if not isinstance(access, dict):
        raise ValueError("Client access config must be an object")
    client_keys = access.setdefault("api-keys", [])
    if not isinstance(client_keys, list) or not all(isinstance(key, str) for key in client_keys):
        raise ValueError("Client API keys must be a list of strings")
    if keys["client"] not in client_keys:
        client_keys.append(keys["client"])
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
