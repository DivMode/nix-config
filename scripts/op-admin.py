"""1Password vault administration without the owner's approval prompt.

  op-admin.py CONNECT_ENV REFERENCE vault create NAME
  op-admin.py CONNECT_ENV REFERENCE vault delete NAME     # only vaults it created
  op-admin.py CONNECT_ENV REFERENCE item move ITEM --current-vault A --destination-vault B
  op-admin.py CONNECT_ENV - setup VAULT NAME     # once, with the owner's approval

`op` through the desktop app asks the owner to approve every session, and the
owner wants vaults created and items moved while away (2026-10-07). This runs
`op` as a dedicated service account instead. Its token is the field
`credential` of the item REFERENCE names (local.nix
onePassword.opAdminReference); it is read through Connect for each call and
given only to the `op` child, never written to disk or printed.

Only `vault create`, `vault delete` (its own vaults) and `item move`/`mv` (without --reveal, output discarded:
it prints the moved item) run. A service account cannot reach the built-in
Personal, Private or Employee vaults or the default Shared vault, cannot
grant Connect a vault (`nix-config-connect-rotate` does that, with the
owner's approval), and keeps the vault access it was created with; vaults it
creates it can use.

`setup` creates the service account with the owner's approval: allowed to
create vaults, with read and write access to every vault this Mac's Connect
token sees. Its token goes straight from `op` into a new API Credential item in
VAULT, written through Connect and read back; the command prints the op://
reference to put in local.nix.
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from onepassword_connect import Connect, ConnectError, run  # noqa: E402

FIELD = "credential"
# `vault delete` reaches only vaults this account created: 1Password limits
# a service account to deleting its own.
ALLOWED = {("vault", "create"), ("vault", "delete"), ("item", "move"), ("item", "mv")}


def op_binary():
    binary = shutil.which("op")
    if not binary:
        raise ConnectError("the 1Password CLI (`op`, the 1password-cli cask) is not on PATH")
    return binary


def parse_reference(reference):
    parts = reference.removeprefix("op://").split("/")
    if not reference.startswith("op://") or len(parts) != 3 or not all(parts):
        raise ConnectError("local.nix sets no onePassword.opAdminReference (op://vault/item/credential); "
                           "run `nix-config-op-admin setup VAULT NAME` once")
    return parts


def administer(connect_env, reference, args):
    if tuple(args[:2]) not in ALLOWED:
        raise ConnectError("only `vault create NAME`, `vault delete NAME` (a vault this account "
                           "created) and `item move ITEM --current-vault A --destination-vault B` are allowed")
    if "--reveal" in args:
        raise ConnectError("--reveal would print the item's concealed fields")
    vault, item, field = parse_reference(reference)
    token = Connect(connect_env).field(vault, item, field)
    # Every OP_* the caller had is dropped: OP_CONNECT_* would make `op` use
    # Connect, and a session variable could make it use the owner's account.
    env = {k: v for k, v in os.environ.items() if not k.startswith("OP_")}
    env["OP_SERVICE_ACCOUNT_TOKEN"] = token
    moving = args[0] == "item"
    result = subprocess.run([op_binary(), *args], env=env, text=True,
                            stdout=subprocess.DEVNULL if moving else None)
    if result.returncode != 0:
        raise ConnectError(f"`op {' '.join(args[:2])}` failed (exit {result.returncode})")
    if moving:
        print(f"moved '{args[2]}' (the moved item's details were not printed)")


def setup(connect_env, vault, name):
    connect = Connect(connect_env)
    vault_id = connect.vault_id(vault)
    vaults = connect.get("/v1/vaults")
    vault_ids = sorted(v["id"] for v in vaults if isinstance(v, dict) and isinstance(v.get("id"), str))
    print(f"creating service account '{name}': may create vaults; read and write in "
          f"{len(vault_ids)} vaults (those this Mac's Connect token sees)")
    vault_args = [arg for vid in vault_ids for arg in ("--vault", f"{vid}:read_items,write_items")]
    workdir = tempfile.mkdtemp(prefix="op-admin-")
    token_file = os.path.join(workdir, "token")
    keep = False
    try:
        descriptor = os.open(token_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            result = subprocess.run([op_binary(), "service-account", "create", name, "--can-create-vaults",
                                     *vault_args, "--raw"], stdout=handle, stderr=subprocess.PIPE, text=True)
        if result.returncode != 0:
            raise ConnectError(f"`op service-account create` failed: {result.stderr.strip()}")
        token = Path(token_file).read_text().strip()
        if not token:
            raise ConnectError("`op service-account create` returned no token")
        # From here the token exists only in this file until it is stored:
        # `op` returns it once. On failure the file is kept and named.
        keep = True
        written = connect.get(f"/v1/vaults/{vault_id}/items", method="POST", body={
            "vault": {"id": vault_id}, "title": name, "category": "API_CREDENTIAL",
            "fields": [{"id": FIELD, "label": FIELD, "type": "CONCEALED", "value": token}],
        })
        item_id = written.get("id") if isinstance(written, dict) else None
        if not isinstance(item_id, str):
            raise ConnectError("Connect did not return the created item")
        want = hashlib.sha256(token.encode()).digest()
        deadline = time.monotonic() + 60
        while True:
            try:
                if hashlib.sha256(connect.field(vault_id, item_id, FIELD).encode()).digest() == want:
                    break
            except ConnectError:
                pass
            if time.monotonic() > deadline:
                raise ConnectError("the stored item does not hold the token 60 s after the write")
            time.sleep(2)
        keep = False
        print(f"stored and read back. Set in local.nix:\n"
              f'  onePassword.opAdminReference = "op://{vault_id}/{item_id}/{FIELD}";')
    except ConnectError as error:
        if keep:
            raise ConnectError(f"{error}. The service account token is still in {token_file} (0600); "
                               "store it before deleting that file, or the account must be recreated")
        raise
    finally:
        if not keep:
            shutil.rmtree(workdir, ignore_errors=True)


def main():
    if len(sys.argv) == 6 and sys.argv[3] == "setup":
        setup(sys.argv[1], sys.argv[4], sys.argv[5])
        return
    if len(sys.argv) < 5:
        raise ConnectError("usage: nix-config-op-admin vault create NAME | item move ITEM --current-vault A "
                           "--destination-vault B | setup VAULT NAME")
    administer(sys.argv[1], sys.argv[2], sys.argv[3:])


if __name__ == "__main__":
    run(main)
