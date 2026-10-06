"""AWS credential_process: aws-credential-connect CONNECT_ENV VAULT ITEM.

Reads the access-key pair from 1Password Connect only; no fallback.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from onepassword_connect import Connect, ConnectError, run  # noqa: E402


def main():
    if len(sys.argv) != 4:
        raise ConnectError("usage: aws-credential-connect CONNECT_ENV VAULT ITEM")
    connect = Connect(sys.argv[1])
    vault, item = sys.argv[2:]
    print(json.dumps({
        "Version": 1,
        "AccessKeyId": connect.field(vault, item, "access key id"),
        "SecretAccessKey": connect.field(vault, item, "secret access key"),
    }))


run(main)
