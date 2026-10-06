"""Save a document's file: onepassword-connect-document CONNECT_ENV VAULT TITLE OUTPUT.

Writes OUTPUT as mode 0600, refusing to overwrite. Connect only.
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from onepassword_connect import Connect, ConnectError, run  # noqa: E402


def main():
    if len(sys.argv) != 5:
        raise ConnectError("usage: onepassword-connect-document CONNECT_ENV VAULT TITLE OUTPUT")
    connect_env, vault, title, output = sys.argv[1:]
    content = Connect(connect_env).document(vault, title)
    try:
        descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except OSError:
        raise ConnectError(f"cannot create {output} (it must not already exist)") from None
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(content)


run(main)
