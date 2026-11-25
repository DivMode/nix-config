"""Print one field: onepassword-connect-read CONNECT_ENV op://VAULT/ITEM/FIELD.

VAULT and ITEM are IDs or exact names; FIELD is a label. Connect only.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from onepassword_connect import Connect, ConnectError, reference_parts, run  # noqa: E402


def main():
    if len(sys.argv) != 3:
        raise ConnectError("usage: onepassword-connect-read CONNECT_ENV op://VAULT/ITEM/FIELD")
    reference = reference_parts(sys.argv[2])
    sys.stdout.write(Connect(sys.argv[1]).field(*reference))


run(main)
