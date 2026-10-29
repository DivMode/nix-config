"""Create, update or delete an item through Connect, then read it back.

  onepassword-connect-item CONNECT_ENV put VAULT TITLE FILE
  onepassword-connect-item CONNECT_ENV delete VAULT TITLE

FILE is JSON: {"category": "API_CREDENTIAL", "fields": [{"label": "api_token",
"type": "CONCEALED", "value": "..."}, ...]}. `category` is used only when the
item is created (default API_CREDENTIAL); `type` defaults to CONCEALED. FILE
must be a regular file readable only by its owner (mode 0600): it holds secret
values, which never go in argv.

A field may also give an "id": the id of one of the category's built-in fields,
such as "credential" in API_CREDENTIAL or "password" in LOGIN. Without it,
Connect stores a custom field with a generated id, and readers that address
built-in fields by id (the 1Password Pulumi provider among them) do not see it
even though the label matches. With it, a new item gets the built-in field, and
on an existing item the field with that id, or else the one with that label,
becomes the built-in field.

FILE may also give "urls": ["https://...", ...], the item's websites, first one
primary. The browser extension offers a LOGIN or PASSWORD item on the pages
those name; an API_CREDENTIAL is never filled into a page. When given, they
replace the item's websites.

When VAULT holds an item titled TITLE, its fields with the same labels (or ids)
are replaced and new labels are added; other fields are kept. Otherwise the item
is created. The command then reads the item back until every value, id and
website matches, and prints only the vault, item ID and field labels, never a
value.

`delete` removes the one item titled TITLE in VAULT. It refuses when no item or
more than one has that title, then reads the item back until Connect no longer
has it, and prints only the vault and item ID.
"""

import json
import re
import os
import stat
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from onepassword_connect import ID, Connect, ConnectError, NotFound, run  # noqa: E402

TYPES = {"STRING", "CONCEALED", "EMAIL", "URL", "OTP", "PHONE"}
FIELD_ID = re.compile(r"[A-Za-z][A-Za-z0-9_]{0,63}")


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
        field_id = field.get("id")
        if field_id is not None and (not isinstance(field_id, str) or not FIELD_ID.fullmatch(field_id)):
            raise ConnectError(f"field '{label}' has an invalid id; use a built-in field id such as credential")
        wanted[label] = (kind, value, field_id)
    category = spec.get("category", "API_CREDENTIAL")
    if not isinstance(category, str) or not category:
        raise ConnectError('"category" must be a 1Password category name')
    urls = spec.get("urls")
    if urls is not None and (
        not isinstance(urls, list) or not urls
        or not all(isinstance(url, str) and urllib.parse.urlsplit(url).scheme in {"http", "https"}
                   and urllib.parse.urlsplit(url).netloc for url in urls)
    ):
        raise ConnectError('"urls" must be a non-empty list of http(s) addresses')
    return category, wanted, urls


def websites(urls):
    """The Connect url objects for the wanted websites, the first primary."""
    return [{"href": url, "primary": index == 0} for index, url in enumerate(urls)]


def entry(label, spec):
    """The Connect field object for one wanted field."""
    kind, value, field_id = spec
    field = {"label": label, "type": kind, "value": value}
    if field_id is not None:
        field["id"] = field_id
    return field


def existing(connect, vault_id, title):
    if not title.strip() or '"' in title or "\\" in title:
        raise ConnectError("the title must be non-empty, without quotes or backslashes")
    query = urllib.parse.quote(f'title eq "{title}"')
    rows = [row for row in connect.get(f"/v1/vaults/{vault_id}/items?filter={query}") or []
            if isinstance(row, dict) and row.get("title") == title]
    if len(rows) > 1:
        raise ConnectError(f"{len(rows)} items are titled {title}; keep one before writing")
    return connect.get(f"/v1/vaults/{vault_id}/items/{rows[0]['id']}") if rows else None


def merge(fields, wanted):
    """`fields` with every wanted field set once.

    A named id wins; otherwise the field is found by its label. Other fields
    with that id or label are dropped: readers (onepassword_connect.Connect.
    fields) take the first field with a label, so a second one is a value no
    reader sees. Creating a LOGIN item stored Connect's own empty `password`
    field ahead of the one sent, both with id `password` (2026-10-28).
    """
    fields = [f for f in fields if isinstance(f, dict)]
    for label, spec in wanted.items():
        field_id = spec[2]
        by_id = [f for f in fields if field_id is not None and f.get("id") == field_id]
        same = by_id + [f for f in fields if f.get("label") == label and f not in by_id]
        if not same:
            fields.append(entry(label, spec))
            continue
        same[0].update(entry(label, spec))
        fields = [f for f in fields if f is same[0] or all(f is not s for s in same)]
    return fields


def put(connect, vault, title, path):
    category, wanted, urls = load(path)
    vault_id = connect.vault_id(vault)
    item = existing(connect, vault_id, title)
    outcome = "updated"
    if item is None:
        body = {"vault": {"id": vault_id}, "title": title, "category": category,
                "fields": merge([], wanted)}
        if urls is not None:
            body["urls"] = websites(urls)
        item = connect.get(f"/v1/vaults/{vault_id}/items", method="POST", body=body)
        outcome = "created"
    if not isinstance(item, dict) or not isinstance(item.get("id"), str) or not ID.fullmatch(item["id"]):
        raise ConnectError("Connect did not return the written item")
    item_id = item["id"]
    fields = item.get("fields") or []
    merged = merge(json.loads(json.dumps(fields)), wanted)
    if outcome == "updated" or merged != fields:
        item["fields"] = merged
        if urls is not None:
            item["urls"] = websites(urls)
        connect.get(f"/v1/vaults/{vault_id}/items/{item_id}", method="PUT", body=item)
    # Connect serves reads from a local copy that catches up a few seconds
    # after a write, and a just-created item 404s until then.
    deadline = time.monotonic() + 60
    while True:
        try:
            stored = connect.get(f"/v1/vaults/{vault_id}/items/{item_id}")
        except NotFound:
            stored = None
        problem = f"the stored {title} still does not match 60 s after the write"
        if isinstance(stored, dict):
            stored_fields = [f for f in stored.get("fields") or [] if isinstance(f, dict)]
            duplicates = [
                f"{len(same)} fields labelled {label} ("
                + ", ".join(f"id {f.get('id')} {'set' if f.get('value') else 'empty'}" for f in same) + ")"
                for label in wanted
                if len(same := [f for f in stored_fields if f.get("label") == label]) > 1
            ]
            if duplicates:
                problem = f"{title} still has {'; '.join(duplicates)} 60 s after the write"
            # Read as readers do: the first field with each label.
            values = {}
            for f in stored_fields:
                values.setdefault(f.get("label"), (f.get("type"), f.get("value"), f.get("id")))
            if not duplicates and all(
                (stored_spec := values.get(label)) is not None
                and stored_spec[:2] == (kind, value)
                and (field_id is None or stored_spec[2] == field_id)
                for label, (kind, value, field_id) in wanted.items()
            ) and (urls is None or [u.get("href") for u in stored.get("urls") or []
                                    if isinstance(u, dict)] == urls):
                break
        if time.monotonic() > deadline:
            raise ConnectError(problem)
        time.sleep(2)
    print(f"{outcome} and read back: {vault_id}/{item_id} ({', '.join(wanted)})")


def delete(connect, vault, title):
    vault_id = connect.vault_id(vault)
    item = existing(connect, vault_id, title)
    item_id = item.get("id") if isinstance(item, dict) else None
    if not isinstance(item_id, str) or not ID.fullmatch(item_id):
        raise ConnectError(f"no item is titled {title}")
    connect.raw(f"/v1/vaults/{vault_id}/items/{item_id}", method="DELETE")
    # As after a write, Connect's local copy may still serve the item briefly.
    deadline = time.monotonic() + 60
    while True:
        try:
            connect.get(f"/v1/vaults/{vault_id}/items/{item_id}")
        except NotFound:
            break
        if time.monotonic() > deadline:
            raise ConnectError(f"Connect still has {title} 60 s after the delete")
        time.sleep(2)
    print(f"deleted and read back as gone: {vault_id}/{item_id}")


USAGE = "usage: nix-config-connect-item put VAULT TITLE FILE | delete VAULT TITLE"


def main():
    command = sys.argv[2] if len(sys.argv) > 2 else None
    if command == "put" and len(sys.argv) == 6:
        put(Connect(sys.argv[1]), sys.argv[3], sys.argv[4], sys.argv[5])
    elif command == "delete" and len(sys.argv) == 5:
        delete(Connect(sys.argv[1]), sys.argv[3], sys.argv[4])
    else:
        raise ConnectError(USAGE)


run(main)
