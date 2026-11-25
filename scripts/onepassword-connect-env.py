"""Maintain the Connect environment without passing credential values in argv."""

import argparse
import fcntl
import os
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path

from onepassword_connect import (
    FALLBACK_KEYS, HOST_KEY, TOKEN_KEY, Connect, ConnectError,
    fallback_headers, read_env, reference_parts, run,
)


@contextmanager
def candidate_env(env_path, values):
    # mkstemp creates a private file. A rename publishes the entire
    # cache together and leaves readers of the previous file undisturbed.
    fd, name = tempfile.mkstemp(prefix=f".{env_path.name}.", dir=env_path.parent)
    candidate = Path(name)
    try:
        with os.fdopen(fd, "w") as handle:
            os.fchmod(handle.fileno(), 0o600)
            for key, value in values.items():
                handle.write(f"{key}={value}\n")
        yield candidate
    finally:
        candidate.unlink(missing_ok=True)


def refresh(env_path, host, id_ref, secret_ref):
    connect = Connect(env_path, primary_only=True)
    id_vault, id_item, id_field = reference_parts(id_ref)
    secret_vault, secret_item, secret_field = reference_parts(secret_ref)
    if (id_vault, id_item) == (secret_vault, secret_item):
        client_id, client_secret = connect.fields(id_vault, id_item, id_field, secret_field)
    else:
        client_id = connect.field(id_vault, id_item, id_field)
        client_secret = connect.field(secret_vault, secret_item, secret_field)
    fallback_headers(connect.host, host, client_id, client_secret)
    values = read_env(env_path)
    updated = values | dict(zip(FALLBACK_KEYS, (host, client_id, client_secret)))
    if updated != values:
        with candidate_env(env_path, updated) as candidate:
            candidate.replace(env_path)


def clear_fallback(env_path):
    values = read_env(env_path)
    updated = {key: value for key, value in values.items() if key not in FALLBACK_KEYS}
    if updated != values:
        with candidate_env(env_path, updated) as candidate:
            candidate.replace(env_path)


def replace_token(env_path, host, token_path):
    token = "".join(token_path.read_text().split())
    if not token:
        raise ConnectError("the new Connect token file is empty")
    values = {HOST_KEY: host, TOKEN_KEY: token}
    with candidate_env(env_path, values) as candidate:
        # A token change is accepted by the primary before it is published.
        try:
            Connect(candidate).vault_count()
        except ConnectError as error:
            raise ConnectError(f"{error}. The current token is unchanged.") from None
        if env_path.exists():
            previous = read_env(env_path)
            if previous.get(HOST_KEY, "").rstrip("/") == host.rstrip("/"):
                with candidate.open("a") as handle:
                    for key in FALLBACK_KEYS:
                        if key in previous:
                            handle.write(f"{key}={previous[key]}\n")
        candidate.replace(env_path)
    print("Connect accepted the new token; it is now in use.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("env_path", type=Path)
    commands = parser.add_subparsers(dest="command", required=True)
    cache = commands.add_parser("refresh")
    cache.add_argument("host")
    cache.add_argument("id_reference")
    cache.add_argument("secret_reference")
    commands.add_parser("clear-fallback")
    replacement = commands.add_parser("replace-token")
    replacement.add_argument("host")
    replacement.add_argument("token_path", type=Path)
    args = parser.parse_args()

    env_path = args.env_path
    try:
        if args.command == "replace-token":
            env_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            env_path.parent.chmod(0o700)
        # Activation and token replacement must not publish an older token or
        # an older set of Access credentials over one another.
        lock_path = env_path.with_name(f".{env_path.name}.lock")
        lock = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
        with os.fdopen(lock, "r+") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            if args.command == "refresh":
                refresh(env_path, args.host, args.id_reference, args.secret_reference)
            elif args.command == "clear-fallback":
                clear_fallback(env_path)
            else:
                replace_token(env_path, args.host, args.token_path)
    except (ConnectError, OSError) as error:
        if isinstance(error, OSError):
            error = ConnectError(f"could not update the Connect environment: {error.strerror}")
        if args.command != "refresh":
            raise error from None
        print(f"WARNING: could not refresh the Connect fallback: {error}. Keeping the existing cache.",
              file=sys.stderr)


if __name__ == "__main__":
    run(main)
