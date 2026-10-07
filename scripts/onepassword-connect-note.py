"""Host local.nix backup in 1Password through Connect (a Secure Note).

  onepassword-connect-note CONNECT_ENV get  VAULT TITLE OUTPUT   # restore, 0600, never overwrites
  onepassword-connect-note CONNECT_ENV save VAULT TITLE FILE     # create/update, then verify
  onepassword-connect-note CONNECT_ENV list TITLE                # "vault<TAB>title" of notes with that exact title
  onepassword-connect-note CONNECT_ENV check                     # the token is accepted
  onepassword-connect-note CONNECT_ENV vaults                    # "id<TAB>name" of the vaults the token can see

Connect only; any failure exits non-zero with the reason.
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from onepassword_connect import Connect, ConnectError, run  # noqa: E402


def main():
    if len(sys.argv) == 3 and sys.argv[2] == "check":
        Connect(sys.argv[1]).vault_count()
        return
    if len(sys.argv) == 3 and sys.argv[2] == "vaults":
        # IDs and names, neither of them secret: what verifies a vault grant,
        # and what `op connect token create --vault` takes unambiguously.
        vaults = Connect(sys.argv[1]).get("/v1/vaults")
        if not isinstance(vaults, list):
            raise ConnectError("Connect returned an invalid vault list")
        for vault in sorted((v for v in vaults if isinstance(v, dict)), key=lambda v: str(v.get("name", ""))):
            print(f"{vault.get('id', '')}\t{vault.get('name', '')}")
        return
    if len(sys.argv) == 4 and sys.argv[2] == "list":
        for vault, title in Connect(sys.argv[1]).notes_titled(sys.argv[3]):
            print(f"{vault}\t{title}")
        return
    if len(sys.argv) != 6 or sys.argv[2] not in {"get", "save"}:
        raise ConnectError("usage: onepassword-connect-note CONNECT_ENV get|save VAULT TITLE PATH | list TITLE | check | vaults")
    connect_env, action, vault, title, path = sys.argv[1:]
    connect = Connect(connect_env)
    if action == "get":
        text = connect.note_text(vault, title)
        try:
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except OSError:
            raise ConnectError(f"cannot create {path} (it must not already exist)") from None
        # Bytes, not text mode: newline translation would alter the file.
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(text.encode())
        return
    try:
        text = Path(path).read_bytes().decode()
    except (OSError, UnicodeDecodeError):
        raise ConnectError(f"cannot read {path}") from None
    print(connect.save_note(vault, title, text))


run(main)
