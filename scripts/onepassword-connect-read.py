"""Print one field: onepassword-connect-read CONNECT_ENV op://VAULT/ITEM/FIELD.

VAULT and ITEM are IDs or exact names; FIELD is a label. Connect only.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from onepassword_connect import Connect, ConnectError, run  # noqa: E402


def main():
    if len(sys.argv) != 3:
        raise ConnectError("usage: onepassword-connect-read CONNECT_ENV op://VAULT/ITEM/FIELD")
    match = re.fullmatch(r"op://([^/]+)/([^/]+)/([^/?]+)", sys.argv[2])
    if match is None:
        raise ConnectError("the reference must be op://VAULT/ITEM/FIELD")
    sys.stdout.write(Connect(sys.argv[1]).field(*match.groups()))


run(main)
