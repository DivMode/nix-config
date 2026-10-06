"""The one 1Password client for this repository: the Connect REST API.

Every script that reads 1Password imports this module. There is no `op` CLI,
no service account, no desktop application and no fallback: a failure exits
non-zero with the reason, and never prints a secret.
"""

import http.client
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from ipaddress import ip_address
from pathlib import Path

ID = re.compile(r"[a-z0-9]{26}")


class ConnectError(Exception):
    """A Connect failure whose message is safe to print."""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


class Connect:
    def __init__(self, env_path):
        values = {}
        try:
            for line in Path(env_path).read_text().splitlines():
                name, separator, value = line.partition("=")
                if separator and name in {"OP_CONNECT_HOST", "OP_CONNECT_TOKEN"}:
                    values[name] = value.strip().strip("'\"")
        except OSError:
            raise ConnectError(f"the Connect environment {env_path} is unavailable; run scripts/setup-mac.sh") from None
        self.host = values.get("OP_CONNECT_HOST", "").rstrip("/")
        self._token = values.get("OP_CONNECT_TOKEN", "")
        origin = urllib.parse.urlsplit(self.host)
        try:
            private = origin.hostname == "localhost" or ip_address(origin.hostname or "").is_private
        except ValueError:
            private = False
        if (not self._token or origin.username or origin.password or origin.query
                or origin.fragment or origin.path not in {"", "/"}
                or not (origin.scheme == "https" or (origin.scheme == "http" and private))):
            raise ConnectError("the Connect environment is invalid (https, or http on a private address, and a token)")

    def raw(self, path, limit=2 * 1024 * 1024):
        request = urllib.request.Request(
            f"{self.host}{path}",
            headers={"Authorization": f"Bearer {self._token}"},
        )
        try:
            with urllib.request.build_opener(_NoRedirect).open(request, timeout=15) as response:
                body = response.read(limit + 1)
        except urllib.error.HTTPError as error:
            raise ConnectError(f"Connect returned HTTP {error.code} for {path.split('?')[0]}") from None
        except (OSError, http.client.HTTPException):
            # Never echo the response: a malformed status line can carry its text.
            raise ConnectError(f"Connect at {self.host} is unreachable or answered malformed HTTP") from None
        if len(body) > limit:
            raise ConnectError(f"Connect returned more than {limit} bytes for {path.split('?')[0]}")
        return body

    def get(self, path):
        try:
            return json.loads(self.raw(path))
        except ValueError:
            raise ConnectError(f"Connect returned invalid JSON for {path.split('?')[0]}") from None

    def _single(self, path, key, expected, what):
        results = self.get(path)
        if (not isinstance(results, list) or len(results) != 1 or not isinstance(results[0], dict)
                or results[0].get(key) != expected or not ID.fullmatch(str(results[0].get("id", "")))):
            raise ConnectError(f"Connect cannot see exactly one {what}")
        return results[0]["id"]

    def vault_id(self, vault):
        if ID.fullmatch(vault):
            return vault
        query = urllib.parse.quote(f'name eq "{vault}"')
        return self._single(f"/v1/vaults?filter={query}", "name", vault, f"vault named {vault}")

    def item(self, vault, item):
        vault_id = self.vault_id(vault)
        item_id = item
        if not ID.fullmatch(item):
            query = urllib.parse.quote(f'title eq "{item}"')
            item_id = self._single(f"/v1/vaults/{vault_id}/items?filter={query}", "title", item, f"item titled {item}")
        value = self.get(f"/v1/vaults/{vault_id}/items/{item_id}")
        if not isinstance(value, dict) or value.get("id") != item_id or (value.get("vault") or {}).get("id") != vault_id:
            raise ConnectError("Connect returned an unexpected item")
        return value

    def field(self, vault, item, label):
        for field in self.item(vault, item).get("fields") or []:
            if (isinstance(field, dict) and isinstance(field.get("label"), str)
                    and field["label"].strip().lower() == label.strip().lower()):
                value = field.get("value")
                if not isinstance(value, str) or not value:
                    raise ConnectError(f"field '{label}' is empty")
                return value
        raise ConnectError(f"the item has no field '{label}'")

    def ssh_private_key(self, vault, item):
        for field in self.item(vault, item).get("fields") or []:
            if isinstance(field, dict) and field.get("type") == "SSHKEY":
                # OpenSSH form when Connect provides it; otherwise the stored
                # PKCS#8, which OpenSSH 10 reads directly for Ed25519.
                value = ((field.get("ssh_formats") or {}).get("openssh") or {}).get("value") or field.get("value")
                if isinstance(value, str) and value.strip():
                    return value.strip() + "\n"
        raise ConnectError("the item has no SSH private key")

    def document(self, vault, item):
        value = self.item(vault, item)
        files = [f for f in value.get("files") or [] if isinstance(f, dict) and f.get("id")]
        if len(files) != 1:
            raise ConnectError(f"the document item has {len(files)} files, not one")
        return self.raw(f"/v1/vaults/{value['vault']['id']}/items/{value['id']}/files/{files[0]['id']}/content")


def run(main):
    """Run `main`, turning ConnectError into a loud non-zero exit."""
    try:
        main()
    except ConnectError as error:
        print(f"{Path(sys.argv[0]).stem}: ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
