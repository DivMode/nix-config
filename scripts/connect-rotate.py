"""Replace this Mac's 1Password Connect token, optionally granting it more vaults.

  connect-rotate.py CONNECT_ENV CONNECT_HOST SERVER SET_TOKEN STORE_TOKEN \
      [--add-vault VAULT]... [--name NAME] [--dry-run]

A Connect token's vaults are fixed when it is issued, so giving this Mac a new
vault means a new token. Done by hand on 2026-10-06 that took a dozen steps and
went wrong twice (vault names with spaces rejected; the stored copy written
into a Document item, which Connect cannot write). In order, this:

  1. reads the vaults the token in use can see, through Connect;
  2. grants SERVER each added vault (`op connect vault grant`; a name is
     turned into its ID with `op vault list`, metadata only);
  3. issues a token for the old vaults plus the new ones, by vault ID, straight
     into a private 0600 file (`op connect token create`);
  4. checks through Connect that the new token sees exactly those vaults;
  5. installs it with SET_TOKEN (which re-checks it before replacing the env
     file) and updates the 1Password copy with STORE_TOKEN, then confirms both.

It never deletes the old token: other machines or clusters may still use it.
It prints that token's ID and the command to delete it once nothing does.
Steps 2 and 3 use `op` (the owner's 1Password approval).
No token is ever printed or passed as an argument.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from onepassword_connect import Connect, ConnectError, run  # noqa: E402

import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "connect_store_token", Path(__file__).resolve().parent / "connect-store-token.py")
_store = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_store)
claims = _store.claims


def visible_vaults(env_path):
    vaults = Connect(env_path).get("/v1/vaults")
    if not isinstance(vaults, list):
        raise ConnectError("Connect returned an invalid vault list")
    return {v["id"]: v.get("name", "") for v in vaults if isinstance(v, dict) and isinstance(v.get("id"), str)}


class Op:
    def __init__(self, server):
        self.binary = shutil.which("op")
        if not self.binary:
            raise ConnectError("the 1Password CLI (`op`, the 1password-cli cask) is not on PATH")
        self.server = server

    def _run(self, *args, stdout=subprocess.PIPE):
        result = subprocess.run([self.binary, "connect", *args, "--server", self.server],
                                stdout=stdout, stderr=subprocess.PIPE, text=True)
        if result.returncode != 0:
            raise ConnectError(f"`op connect {' '.join(args[:2])}` failed: {result.stderr.strip()}")
        return result.stdout

    def _json(self, *args):
        try:
            data = json.loads(self._run(*args, "--format", "json") or "[]")
        except json.JSONDecodeError as error:
            raise ConnectError(f"`op connect {' '.join(args)}` did not return JSON: {error}")
        return [entry for entry in data if isinstance(entry, dict)] if isinstance(data, list) else []

    def account_vaults(self):
        """Vault IDs and names from the account (`op vault list`): metadata
        only, and the one way to turn a name into the ID `token create` needs
        (it reads a name with a space as an ID: "unable to find vault with ID
        'Options Console'", 2026-10-06). This `op` has no `connect vault list`."""
        result = subprocess.run([self.binary, "vault", "list", "--format", "json"],
                                capture_output=True, text=True)
        if result.returncode != 0:
            raise ConnectError(f"`op vault list` failed: {result.stderr.strip()}")
        data = json.loads(result.stdout or "[]")
        return {v["id"]: v.get("name", "") for v in data if isinstance(v, dict) and isinstance(v.get("id"), str)}

    def grant(self, vault_id):
        self._run("vault", "grant", "--vault", vault_id)

    def tokens(self):
        return self._json("token", "list")

    def create_token(self, name, vault_ids, output):
        vault_args = [arg for vault_id in sorted(vault_ids) for arg in ("--vault", vault_id)]
        descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            self._run("token", "create", name, *vault_args, stdout=handle)


def resolve(requested, vaults):
    """A vault ID or exact name among the account's vaults, or None."""
    if requested in vaults:
        return requested
    matches = [vault_id for vault_id, name in vaults.items() if name == requested]
    if len(matches) > 1:
        raise ConnectError(f"more than one vault is named '{requested}'; pass its ID")
    return matches[0] if matches else None


def unused_name(base, tokens):
    taken = {t.get("name") for t in tokens}
    name, n = base, 2
    while name in taken:
        name, n = f"{base}-{n}", n + 1
    return name


def confirm(command, *args):
    result = subprocess.run([command, *args], capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if result.returncode != 0:
        raise ConnectError(f"{Path(command).name} {' '.join(args)} failed (exit {result.returncode})")


def main():
    parser = argparse.ArgumentParser(prog="nix-config-connect-rotate",
                                     description="Replace this Mac's Connect token, optionally with more vaults.")
    for positional in ("connect_env", "connect_host", "server", "set_token", "store_token"):
        parser.add_argument(positional, help=argparse.SUPPRESS)
    parser.add_argument("--add-vault", action="append", default=[], metavar="VAULT",
                        help="vault name or ID to add (repeatable)")
    parser.add_argument("--name", help="token name (default: mac-YYYY-MM-DD)")
    parser.add_argument("--dry-run", action="store_true", help="show the plan; issue and change nothing")
    args = parser.parse_args()
    if not args.server:
        raise ConnectError("local.nix sets no onePassword.connectServer (the Connect server's name)")

    current = visible_vaults(args.connect_env)
    old_token = Connect(args.connect_env)._token
    print(f"Token in use ({claims(old_token) or 'not a JWT'}) sees {len(current)} vaults: "
          + ", ".join(sorted(current.values())))

    op = Op(args.server)
    added = {}
    if args.add_vault:
        account = None
        for requested in args.add_vault:
            # A vault the token in use already sees needs nothing; only the
            # others are looked up in the account.
            if resolve(requested, current) is not None:
                print(f"'{requested}' is already one of this token's vaults")
                continue
            if account is None:
                account = op.account_vaults()
            vault_id = resolve(requested, account)
            if vault_id is None:
                raise ConnectError(f"no vault named or with ID '{requested}' among the {len(account)} vaults "
                                   f"`op vault list` returned: {', '.join(sorted(account.values()))}. "
                                   "A vault your account is not a member of is not listed; pass its ID")
            added[vault_id] = account[vault_id]
        for vault_id, vault_name in added.items():
            if args.dry_run:
                print(f"would grant {args.server} the vault '{vault_name}' ({vault_id})")
                continue
            print(f"granting {args.server} the vault '{vault_name}' ({vault_id})")
            try:
                op.grant(vault_id)
            except ConnectError as error:
                # Re-granting a vault the server already has may fail; the
                # new token's vault check below is what decides.
                print(f"  grant reported: {error}; continuing, the new token's vault check decides")
    wanted = {**current, **added}

    tokens = op.tokens()
    name = unused_name(args.name or f"mac-{date.today().isoformat()}", tokens)
    print(f"New token '{name}' for {len(wanted)} vaults: " + ", ".join(sorted(wanted.values())))
    if args.dry_run:
        print("Dry run: nothing issued or changed.")
        return

    workdir = tempfile.mkdtemp(prefix="connect-rotate-")
    try:
        token_file = os.path.join(workdir, "token")
        op.create_token(name, wanted, token_file)
        token = Path(token_file).read_text().strip()
        if not token or claims(token) is None:
            raise ConnectError(f"`op connect token create` returned no token; check `op connect token list` for '{name}'")
        candidate = os.path.join(workdir, "connect.env")
        descriptor = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            handle.write(f"OP_CONNECT_HOST={args.connect_host}\nOP_CONNECT_TOKEN={token}\n")
        del token
        # A just-issued token can take a moment to be accepted; bounded wait.
        deadline = time.monotonic() + 30
        while True:
            try:
                seen = visible_vaults(candidate)
                break
            except ConnectError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(2)
        if set(seen) != set(wanted):
            raise ConnectError(f"the new token '{name}' sees {sorted(seen.values())}, not {sorted(wanted.values())}; "
                               f"the token in use is unchanged. Delete the new one: "
                               f"op connect token delete {name} --server {args.server}")
        confirm(args.set_token, token_file)
        confirm(args.store_token, "store")
        confirm(args.store_token, "ids")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    old_claims = claims(old_token) or ""
    old_id = old_claims.split()[0].removeprefix("jti=") if old_claims else "the previous token"
    old = next((t for t in tokens if t.get("id") == old_id), {})
    print(f"Done. The previous token ({old.get('name') or old_id}) still works. Once nothing else uses it:\n"
          f"  op connect token delete {old.get('name') or old_id} --server {args.server}")


if __name__ == "__main__":
    run(main)
