"""Create or update an item through Connect, then read it back.

  onepassword-connect-item CONNECT_ENV put VAULT TITLE FILE

FILE is JSON: {"category": "API_CREDENTIAL", "fields": [{"label": "api_token",
"type": "CONCEALED", "value": "..."}, ...]}. `category` is used only when the
item is created (default API_CREDENTIAL); `type` defaults to CONCEALED. FILE
must be a regular file readable only by its owner (mode 0600): it holds secret
values, which never go in argv.

When VAULT holds an item titled TITLE, its fields with the same labels are
replaced and new labels are added; other fields are kept. Otherwise the item is
created. The command then reads the item back until every value matches, and
prints only the vault, item ID and field labels, never a value.
"""

import json
import os
import stat
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from onepassword_connect import ID, Connect, ConnectError, NotFound, run  # noqa: E402

TYPES = {"STRING", "CONCEALED", "EMAIL", "URL", "OTP", "PHONE"}


def load(path):
    try:
        info = os.stat(path)
    except OSError:
        raise ConnectError(f"cannot read {path}") from None
    if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
        raise ConnectError(f"{path} must be a regular file with mode 0600: it holds secret values")
    try:
        spec = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        raise ConnectError(f"{path} is not valid JSON") from None
    fields = spec.get("fields") if isinstance(spec, dict) else None
    if not isinstance(fields, list) or not fields:
        raise ConnectError('the file needs a non-empty "fields" list')
    wanted = {}
    for field in fields:
        label = field.get("label") if isinstance(field, dict) else None
        value = field.get("value") if isinstance(field, dict) else None
        kind = field.get("type", "CONCEALED") if isinstance(field, dict) else None
        if not isinstance(label, str) or not label.strip() or not isinstance(value, str) or not value:
            raise ConnectError("every field needs a non-empty label and value")
        if kind not in TYPES:
            raise ConnectError(f"field '{label}' has type {kind!r}; use one of {sorted(TYPES)}")
        if label in wanted:
            raise ConnectError(f"field '{label}' appears twice")
        wanted[label] = (kind, value)
    category = spec.get("category", "API_CREDENTIAL")
    if not isinstance(category, str) or not category:
        raise ConnectError('"category" must be a 1Password category name')
    return category, wanted


def existing(connect, vault_id, title):
    query = urllib.parse.quote(f'title eq "{title}"')
    rows = [row for row in connect.get(f"/v1/vaults/{vault_id}/items?filter={query}") or []
            if isinstance(row, dict) and row.get("title") == title]
    if len(rows) > 1:
        raise ConnectError(f"{len(rows)} items are titled {title}; keep one before writing")
    return connect.get(f"/v1/vaults/{vault_id}/items/{rows[0]['id']}") if rows else None


def put(connect, vault, title, path):
    if not title.strip() or '"' in title or "\\" in title:
        raise ConnectError("the title must be non-empty, without quotes or backslashes")
    category, wanted = load(path)
    vault_id = connect.vault_id(vault)
    item = existing(connect, vault_id, title)
    if item is None:
        written = connect.get(f"/v1/vaults/{vault_id}/items", method="POST", body={
            "vault": {"id": vault_id}, "title": title, "category": category,
            "fields": [{"label": label, "type": kind, "value": value} for label, (kind, value) in wanted.items()],
        })
        outcome = "created"
    else:
        fields = [f for f in item.get("fields") or [] if isinstance(f, dict)]
        for field in fields:
            if field.get("label") in wanted:
                field["type"], field["value"] = wanted[field["label"]]
        present = {f.get("label") for f in fields}
        fields += [{"label": label, "type": kind, "value": value}
                   for label, (kind, value) in wanted.items() if label not in present]
        item["fields"] = fields
        written = connect.get(f"/v1/vaults/{vault_id}/items/{item['id']}", method="PUT", body=item)
        outcome = "updated"
    item_id = written.get("id") if isinstance(written, dict) else None
    if not isinstance(item_id, str) or not ID.fullmatch(item_id):
        raise ConnectError("Connect did not return the written item")
    # Connect serves reads from a local copy that catches up a few seconds
    # after a write, and a just-created item 404s until then.
    deadline = time.monotonic() + 60
    while True:
        try:
            stored = connect.get(f"/v1/vaults/{vault_id}/items/{item_id}")
        except NotFound:
            stored = None
        if isinstance(stored, dict):
            values = {f.get("label"): (f.get("type"), f.get("value"))
                      for f in stored.get("fields") or [] if isinstance(f, dict)}
            if all(values.get(label) == spec for label, spec in wanted.items()):
                break
        if time.monotonic() > deadline:
            raise ConnectError(f"the stored {title} still does not match 60 s after the write")
        time.sleep(2)
    print(f"{outcome} and read back: {vault_id}/{item_id} ({', '.join(wanted)})")


def main():
    if len(sys.argv) != 6 or sys.argv[2] != "put":
        raise ConnectError("usage: nix-config-connect-item put VAULT TITLE FILE")
    put(Connect(sys.argv[1]), sys.argv[3], sys.argv[4], sys.argv[5])


run(main)
