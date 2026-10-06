"""Host local.nix backup in 1Password through Connect (a Secure Note).

  onepassword-connect-note CONNECT_ENV get  VAULT TITLE OUTPUT   # restore, 0600, never overwrites
  onepassword-connect-note CONNECT_ENV save VAULT TITLE FILE     # create/update, then verify
  onepassword-connect-note CONNECT_ENV list PREFIX               # "vault<TAB>title" of matching notes

Connect only; any failure exits non-zero with the reason.
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from onepassword_connect import Connect, ConnectError, run  # noqa: E402


def main():
    if len(sys.argv) == 4 and sys.argv[2] == "list":
        for vault, title in Connect(sys.argv[1]).notes_titled(sys.argv[3]):
            print(f"{vault}\t{title}")
        return
    if len(sys.argv) != 6 or sys.argv[2] not in {"get", "save"}:
        raise ConnectError("usage: onepassword-connect-note CONNECT_ENV get|save VAULT TITLE PATH | list PREFIX")
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
