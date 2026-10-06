"""Print one field from 1Password Connect: onepassword-connect-read CONNECT_ENV op://VAULT/ITEM/FIELD

Connect only. No `op` CLI, no service account, no desktop application, and no
fallback: when Connect cannot answer, this fails with the reason. VAULT and
ITEM may be IDs or exact names; FIELD is matched by label, case-insensitively.
"""

import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from ipaddress import ip_address
from pathlib import Path


def fail(message):
    print(f"onepassword-connect-read: {message}", file=sys.stderr)
    raise SystemExit(1)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


if len(sys.argv) != 3:
    fail("usage: onepassword-connect-read CONNECT_ENV op://VAULT/ITEM/FIELD")
connect_env, reference = sys.argv[1:]
match = re.fullmatch(r"op://([^/]+)/([^/]+)/([^/?]+)", reference)
if match is None:
    fail("the reference must be op://VAULT/ITEM/FIELD")
vault, item_ref, field_label = match.groups()

connect = {}
try:
    for line in Path(connect_env).read_text().splitlines():
        name, separator, value = line.partition("=")
        if separator and name in {"OP_CONNECT_HOST", "OP_CONNECT_TOKEN"}:
            connect[name] = value.strip().strip("'\"")
except OSError:
    fail(f"the Connect environment {connect_env} is unavailable; run scripts/setup-mac.sh connect")
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


def is_id(value):
    return re.fullmatch(r"[a-z0-9]{26}", value) is not None


def single(results, what):
    if not isinstance(results, list) or len(results) != 1 or not isinstance(results[0], dict):
        fail(f"Connect cannot see exactly one {what}")
    return results[0].get("id", "")


vault_id = vault if is_id(vault) else single(
    get(f"/v1/vaults?filter={urllib.parse.quote(f'name eq \"{vault}\"')}"), f"vault named {vault}")
item_id = item_ref if is_id(item_ref) else single(
    get(f"/v1/vaults/{vault_id}/items?filter={urllib.parse.quote(f'title eq \"{item_ref}\"')}"),
    f"item titled {item_ref}")
item = get(f"/v1/vaults/{vault_id}/items/{item_id}")
if not isinstance(item, dict) or item.get("id") != item_id:
    fail("Connect returned an unexpected item")
for field in item.get("fields") or []:
    if (isinstance(field, dict) and isinstance(field.get("label"), str)
            and field["label"].strip().lower() == field_label.strip().lower()):
        value = field.get("value")
        if not isinstance(value, str) or not value:
            fail(f"field '{field_label}' is empty")
        sys.stdout.write(value)
        raise SystemExit(0)
fail(f"item has no field '{field_label}'")
