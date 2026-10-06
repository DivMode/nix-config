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
    access_key_id, secret_access_key = Connect(sys.argv[1]).fields(
        sys.argv[2], sys.argv[3], "access key id", "secret access key")
    print(json.dumps({"Version": 1, "AccessKeyId": access_key_id, "SecretAccessKey": secret_access_key}))


run(main)
