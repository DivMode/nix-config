"""AWS credential_process: read an access-key pair from 1Password Connect.

Connect only. No `op` CLI, no service account, no desktop application, and no
fallback: if Connect cannot answer, the AWS call fails with the reason.
"""

import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from ipaddress import ip_address
from pathlib import Path


def fail(message):
    print(f"aws-credential-connect: {message}", file=sys.stderr)
    raise SystemExit(1)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


if len(sys.argv) != 4:
    fail("usage: aws-credential-connect CONNECT_ENV VAULT ITEM_ID")
connect_env, vault, item_id = sys.argv[1:]

connect = {}
try:
    for line in Path(connect_env).read_text().splitlines():
        name, separator, value = line.partition("=")
        if separator and name in {"OP_CONNECT_HOST", "OP_CONNECT_TOKEN"}:
            connect[name] = value.strip().strip("'\"")
except OSError:
    fail(f"the Connect environment {connect_env} is unavailable; run the setup bootstrap")
host, token = connect.get("OP_CONNECT_HOST", ""), connect.get("OP_CONNECT_TOKEN", "")
origin = urllib.parse.urlsplit(host)
try:
    private_host = origin.hostname == "localhost" or ip_address(origin.hostname or "").is_private
except ValueError:
    private_host = False
if (not token or origin.username or origin.password or origin.query or origin.fragment
        or origin.path not in {"", "/"}
        or not (origin.scheme == "https" or (origin.scheme == "http" and private_host))):
    fail("the Connect environment is invalid")


def get(path):
    request = urllib.request.Request(
        f"{host.rstrip('/')}{path}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=10) as response:
            return json.loads(response.read(2 * 1024 * 1024))
    except urllib.error.HTTPError as error:
        fail(f"Connect returned HTTP {error.code} for {path.split('?')[0]}")
    except (OSError, ValueError):
        fail(f"Connect at {host} is unreachable or returned invalid data")


# The vault is configured by name or by ID; the item always by ID.
vault_id = vault
if not (len(vault) == 26 and vault.isalnum() and vault.islower()):
    query = urllib.parse.quote(f'name eq "{vault}"')
    vaults = get(f"/v1/vaults?filter={query}")
    if not isinstance(vaults, list) or len(vaults) != 1:
        fail(f"Connect cannot see exactly one vault named {vault}")
    vault_id = vaults[0].get("id", "")

item = get(f"/v1/vaults/{urllib.parse.quote(vault_id)}/items/{urllib.parse.quote(item_id)}")
if not isinstance(item, dict) or item.get("id") != item_id:
    fail("Connect returned an unexpected item")
values = {}
for field in item.get("fields") or []:
    if isinstance(field, dict) and isinstance(field.get("label"), str):
        values[field["label"].strip().lower()] = field.get("value")
access_key_id = values.get("access key id")
secret_access_key = values.get("secret access key")
if not isinstance(access_key_id, str) or not access_key_id or not isinstance(secret_access_key, str) or not secret_access_key:
    fail(f"item {item_id} lacks a non-empty 'access key id' and 'secret access key'")
print(json.dumps({"Version": 1, "AccessKeyId": access_key_id, "SecretAccessKey": secret_access_key}))
