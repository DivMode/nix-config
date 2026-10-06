"""The one 1Password client for this repository: the Connect REST API.

Every script that reads 1Password imports this module. There is no `op` CLI,
no service account, no desktop application and no fallback: a failure exits
non-zero with the reason, and never prints a secret.
"""

import http.client
import json
import re
import sys
import time
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

    def raw(self, path, limit=2 * 1024 * 1024, method="GET", body=None, timeout=15.0):
        headers = {"Authorization": f"Bearer {self._token}"}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(f"{self.host}{path}", data=data, headers=headers, method=method)
        try:
            with urllib.request.build_opener(_NoRedirect).open(request, timeout=timeout) as response:
                body = response.read(limit + 1)
        except urllib.error.HTTPError as error:
            raise ConnectError(f"Connect returned HTTP {error.code} for {path.split('?')[0]}") from None
        except (OSError, http.client.HTTPException):
            # Never echo the response: a malformed status line can carry its text.
            raise ConnectError(f"Connect at {self.host} is unreachable or answered malformed HTTP") from None
        if len(body) > limit:
            raise ConnectError(f"Connect returned more than {limit} bytes for {path.split('?')[0]}")
        return body

    def get(self, path, method="GET", body=None, timeout=15.0):
        try:
            return json.loads(self.raw(path, method=method, body=body, timeout=timeout))
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

    def fields(self, vault, item, *labels):
        """Values for `labels`, all from ONE read of the item, so a rotation
        between requests can never pair an old value with a new one."""
        found = {}
        for field in self.item(vault, item).get("fields") or []:
            if isinstance(field, dict) and isinstance(field.get("label"), str):
                found.setdefault(field["label"].strip().lower(), field.get("value"))
        values = []
        for label in labels:
            value = found.get(label.strip().lower())
            if not isinstance(value, str) or not value:
                raise ConnectError(f"the item has no non-empty field '{label}'")
            values.append(value)
        return values

    def field(self, vault, item, label):
        return self.fields(vault, item, label)[0]

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


    # Secure Notes: the one item category Connect can both create and update
    # that holds free text, used for each host's local.nix (Connect cannot
    # write Document items or files).
    def _note(self, vault_id, title):
        query = urllib.parse.quote(f'title eq "{title}"')
        notes = [n for n in self.get(f"/v1/vaults/{vault_id}/items?filter={query}")
                 if isinstance(n, dict) and n.get("title") == title and n.get("category") == "SECURE_NOTE"]
        if len(notes) > 1:
            raise ConnectError(f"Connect sees {len(notes)} secure notes titled {title}; keep one")
        if not notes:
            return None
        item = self.get(f"/v1/vaults/{vault_id}/items/{notes[0]['id']}")
        if not isinstance(item, dict) or item.get("id") != notes[0]["id"] or (item.get("vault") or {}).get("id") != vault_id:
            raise ConnectError("Connect returned an unexpected item")
        return item

    @staticmethod
    def _notes_field(item):
        for field in item.get("fields") or []:
            if isinstance(field, dict) and field.get("purpose") == "NOTES":
                return field
        raise ConnectError("the secure note has no notes field")

    def vault_count(self):
        """An authenticated read: fails unless the token is accepted."""
        vaults = self.get("/v1/vaults")
        if not isinstance(vaults, list) or not vaults:
            raise ConnectError("the Connect token sees no vaults")
        return len(vaults)

    def notes_titled(self, prefix):
        """(vault name, title) of every Secure Note whose title starts with
        `prefix`, across the vaults this token can see."""
        vaults = self.get("/v1/vaults")
        if not isinstance(vaults, list):
            raise ConnectError("Connect returned an invalid vault list")
        found = []
        for vault in vaults:
            if not isinstance(vault, dict) or not ID.fullmatch(str(vault.get("id", ""))):
                continue
            items = self.get(f"/v1/vaults/{vault['id']}/items")
            for item in items if isinstance(items, list) else []:
                if (isinstance(item, dict) and item.get("category") == "SECURE_NOTE"
                        and isinstance(item.get("title"), str) and item["title"].startswith(prefix)):
                    found.append((str(vault.get("name", vault["id"])), item["title"]))
        return sorted(found)

    def note_text(self, vault, title):
        item = self._note(self.vault_id(vault), title)
        if item is None:
            raise ConnectError(f"no secure note titled {title}")
        value = self._notes_field(item).get("value")
        if not isinstance(value, str) or not value:
            raise ConnectError(f"the secure note {title} is empty")
        return value

    def save_note(self, vault, title, text):
        """Create or update the note, then read it back; returns 'created',
        'updated' or 'unchanged'. Fails unless the stored text matches."""
        vault_id = self.vault_id(vault)
        item = self._note(vault_id, title)
        if item is None:
            written = self.get(f"/v1/vaults/{vault_id}/items", method="POST", body={
                "vault": {"id": vault_id}, "title": title, "category": "SECURE_NOTE",
                "fields": [{"id": "notesPlain", "type": "STRING", "purpose": "NOTES", "label": "notesPlain", "value": text}],
            })
            outcome = "created"
        else:
            field = self._notes_field(item)
            if field.get("value") == text:
                return "unchanged"
            # Connect's JSON Patch addresses a field by its ID, not its index.
            written = self.get(f"/v1/vaults/{vault_id}/items/{item['id']}", method="PATCH",
                               body=[{"op": "replace", "path": f"/fields/{field['id']}/value", "value": text}])
            outcome = "updated"
        # Read back by ID: Connect's title search lags a fresh write
        # (observed 2026-10-06: a created note was not yet listed).
        item_id = written.get("id") if isinstance(written, dict) else None
        if not isinstance(item_id, str) or not ID.fullmatch(item_id):
            raise ConnectError("Connect did not return the written item")
        # Connect serves reads from its local copy, which catches up a few
        # seconds after a write (observed 2026-10-06), so wait a bounded time.
        deadline = time.monotonic() + 60
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ConnectError(f"the stored {title} still does not match 60 s after the write")
            # Each read gets only the time left, so the whole check ends by 60 s.
            stored = self.get(f"/v1/vaults/{vault_id}/items/{item_id}", timeout=min(15.0, remaining))
            if time.monotonic() > deadline:
                raise ConnectError(f"the stored {title} still does not match 60 s after the write")
            if (isinstance(stored, dict) and stored.get("id") == item_id
                    and self._notes_field(stored).get("value") == text):
                return outcome
            time.sleep(min(2.0, max(0.0, deadline - time.monotonic())))


def run(main):
    """Run `main`, turning ConnectError into a loud non-zero exit."""
    try:
        main()
    except ConnectError as error:
        print(f"{Path(sys.argv[0]).stem}: ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
