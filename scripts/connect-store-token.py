"""Keep the 1Password copy of this Mac's Connect token current, through Connect.

  connect-store-token.py CONNECT_ENV REFERENCE ids    # token IDs: stored copy, and the one in use
  connect-store-token.py CONNECT_ENV REFERENCE store  # write the in-use token into the stored copy

REFERENCE is local.nix's onePassword.connectReference (op://vault/item/field),
the item scripts/setup-mac.sh tells a new Mac's owner to copy the token from.
A Connect token's vaults are fixed when it is issued, so granting a vault means
a new token; without this, a new Mac would be set up with the old one.

Never prints a token. `ids` prints only each token's JWT ID (`jti`) and issue
time, which are what `op connect token list` shows and are not secret; `store`
reads the copy back and compares hashes.
"""

import base64
import hashlib
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from onepassword_connect import Connect, ConnectError, run  # noqa: E402


def parse_reference(reference):
    if not reference.startswith("op://"):
        raise ConnectError("the Connect reference is not an op:// URI")
    parts = reference[len("op://"):].split("/")
    if len(parts) != 3 or not all(parts):
        raise ConnectError("the Connect reference must be op://vault/item/field")
    return parts


def claims(token):
    """jti and iat from a Connect token (a JWT), or None if it is not one."""
    try:
        payload = token.split(".")[1]
        data = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (IndexError, ValueError):
        return None
    issued = data.get("iat")
    when = datetime.fromtimestamp(issued, timezone.utc).isoformat() if isinstance(issued, (int, float)) else "?"
    return f"jti={data.get('jti', '?')} issued={when}"


def stored_field(connect, vault, item, field):
    value = connect.item(vault, item)
    for entry in value.get("fields") or []:
        if isinstance(entry, dict) and (entry.get("label") == field or entry.get("id") == field):
            return value, entry
    raise ConnectError(f"the Connect credentials item has no field '{field}'")


def copy_field(connect_env, vault, item, field, output):
    """Write one field's value to a new 0600 file (never printed), and print
    the token ID it carries, so the copy can be checked without reading it."""
    connect = Connect(connect_env)
    _, entry = stored_field(connect, vault, item, field)
    value = entry.get("value") or ""
    if not value:
        raise ConnectError(f"field '{field}' is empty")
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        handle.write(value)
    print(f"copied: {claims(value) or 'not a JWT'}")


def create_item(connect_env, vault, title):
    """Create an API Credential item holding the token in use in a concealed
    `access-token` field, then read it back by ID. A new item never touches
    an existing one, and unlike a Document, Connect writes this category
    correctly (patching the credentials Document dropped its fields)."""
    connect = Connect(connect_env)
    vault_id = connect.vault_id(vault)
    in_use = connect._token
    written = connect.get(f"/v1/vaults/{vault_id}/items", method="POST", body={
        "vault": {"id": vault_id}, "title": title, "category": "API_CREDENTIAL",
        "fields": [{"id": "access-token", "label": "access-token", "type": "CONCEALED", "value": in_use}],
    })
    item_id = written.get("id") if isinstance(written, dict) else None
    if not isinstance(item_id, str):
        raise ConnectError("Connect did not return the created item")
    want = hashlib.sha256(in_use.encode()).digest()
    deadline = time.monotonic() + 60
    while True:
        try:
            _, entry = stored_field(connect, vault_id, item_id, "access-token")
            if hashlib.sha256((entry.get("value") or "").encode()).digest() == want:
                break
        except ConnectError:
            pass
        if time.monotonic() > deadline:
            raise ConnectError("the created item does not hold the token in use 60 s after the write")
        time.sleep(2)
    print(f"created item {item_id} in vault {vault_id}; it holds the token in use ({claims(in_use)})")


def main():
    # create-item VAULT TITLE: a new API Credential holding the token in use.
    if len(sys.argv) == 6 and sys.argv[3] == "create-item":
        create_item(sys.argv[1], sys.argv[4], sys.argv[5])
        return
    # copy-field VAULT ITEM FIELD OUTPUT
    if len(sys.argv) == 8 and sys.argv[3] == "copy-field":
        copy_field(sys.argv[1], *sys.argv[4:8])
        return
    if len(sys.argv) != 4 or sys.argv[3] not in {"ids", "store", "fields"}:
        raise ConnectError("usage: connect-store-token.py CONNECT_ENV REFERENCE ids|store|fields")
    connect_env, reference, action = sys.argv[1:]
    vault, item, field = parse_reference(reference)
    connect = Connect(connect_env)
    if action == "fields":
        # Structure only — id, label, type, purpose, section and value LENGTH.
        whole = connect.item(vault, item)
        print(f"category={whole.get('category')} version={whole.get('version')} "
              f"updated={whole.get('updatedAt')} sections={len(whole.get('sections') or [])}")
        for attachment in whole.get("files") or []:
            if isinstance(attachment, dict):
                print(f"file name={attachment.get('name')!r} size={attachment.get('size')}")
        for entry in whole.get("fields") or []:
            if isinstance(entry, dict):
                print(f"id={entry.get('id')} label={entry.get('label')!r} type={entry.get('type')} "
                      f"purpose={entry.get('purpose')} section={(entry.get('section') or {}).get('id')} "
                      f"value_len={len(entry.get('value') or '')}")
        return
    in_use = connect._token
    value, entry = stored_field(connect, vault, item, field)
    stored = entry.get("value") or ""

    if action == "ids":
        print(f"stored copy: {claims(stored) or 'not a JWT'}")
        print(f"in use:      {claims(in_use) or 'not a JWT'}")
        print("stored copy matches the token in use" if stored == in_use else "stored copy differs from the token in use")
        return

    if stored == in_use:
        print("The stored copy already holds the token in use.")
        return
    if value.get("category") == "DOCUMENT":
        # Connect cannot write Document items: on 2026-10-07 a PATCH of one
        # field left the credentials Document with only an empty notes field.
        raise ConnectError("the stored copy is a Document item, which Connect cannot write safely; "
                           "point onePassword.connectReference at an API Credential (create-item) instead")
    vault_id, item_id = value["vault"]["id"], value["id"]
    # Connect's JSON Patch addresses a field by its ID, not its index.
    connect.get(f"/v1/vaults/{vault_id}/items/{item_id}", method="PATCH",
                body=[{"op": "replace", "path": f"/fields/{entry['id']}/value", "value": in_use}])
    # Connect serves reads from its local copy, which catches up a few seconds
    # after a write (the same lag save_note waits out), so wait a bounded time.
    want = hashlib.sha256(in_use.encode()).digest()
    deadline = time.monotonic() + 60
    while True:
        _, written = stored_field(connect, vault_id, item_id, entry["id"])
        if hashlib.sha256((written.get("value") or "").encode()).digest() == want:
            break
        if time.monotonic() > deadline:
            raise ConnectError("the stored copy still does not match the token in use 60 s after the write")
        time.sleep(2)
    print("Stored copy updated to the token in use, and read back to confirm.")


if __name__ == "__main__":
    run(main)
