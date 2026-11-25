"""The one 1Password client for this repository: the Connect REST API.

Every script that reads 1Password imports this module. The optional second
endpoint is another Connect replica using the same bearer token.
"""

import errno
import http.client
import json
import re
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from functools import partial
from ipaddress import ip_address
from pathlib import Path

ID = re.compile(r"[a-z0-9]{26}")
HOST_KEY = "OP_CONNECT_HOST"
TOKEN_KEY = "OP_CONNECT_TOKEN"
FALLBACK_KEYS = (
    "OP_CONNECT_FALLBACK_HOST",
    "OP_CONNECT_FALLBACK_CF_ACCESS_CLIENT_ID",
    "OP_CONNECT_FALLBACK_CF_ACCESS_CLIENT_SECRET",
)
_CONNECT_ERRNOS = {
    errno.ECONNREFUSED, errno.EHOSTDOWN, errno.EHOSTUNREACH,
    errno.ENETDOWN, errno.ENETUNREACH, errno.ETIMEDOUT,
}


class ConnectError(Exception):
    """A Connect failure whose message is safe to print."""


class NotFound(ConnectError):
    """Connect answered 404."""


class ConnectUnavailable(ConnectError):
    """The primary TCP connection could not be established."""


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def _primary_socket(address, timeout, source_address):
    try:
        sock = socket.create_connection(address, min(2.0, timeout), source_address)
    except OSError as error:
        if isinstance(error, (socket.gaierror, socket.timeout)) or error.errno in _CONNECT_ERRNOS:
            raise ConnectUnavailable("the Connect primary is unreachable") from None
        raise
    # TLS, sending the request, and reading the response use the caller's timeout.
    sock.settimeout(timeout)
    return sock


def _primary_connection(connection_type, host, **kwargs):
    connection = connection_type(host, **kwargs)
    # http.client shares this socket factory between HTTP and HTTPS. Classify
    # only failures here, before TLS or any request bytes can reach the peer.
    connection._create_connection = _primary_socket
    return connection


class _PrimaryHTTPHandler(urllib.request.HTTPHandler):
    def http_open(self, request):
        return self.do_open(partial(_primary_connection, http.client.HTTPConnection), request)


class _PrimaryHTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, request):
        return self.do_open(partial(_primary_connection, http.client.HTTPSConnection), request,
                            context=self._context)


def read_env(env_path):
    values = {}
    try:
        for line in Path(env_path).read_text().splitlines():
            name, separator, value = line.partition("=")
            if separator and name in (HOST_KEY, TOKEN_KEY, *FALLBACK_KEYS):
                values[name] = value.strip().strip("'\"")
    except OSError:
        raise ConnectError(f"the Connect environment {env_path} is unavailable; run scripts/setup-mac.sh") from None
    return values


def reference_parts(reference):
    match = re.fullmatch(r"op://([^/\r\n]+)/([^/\r\n]+)/([^/?\r\n]+)", reference)
    if match is None:
        raise ConnectError("the reference must be op://VAULT/ITEM/FIELD")
    return match.groups()


def fallback_headers(primary_host, host, client_id, client_secret):
    try:
        origin = urllib.parse.urlsplit(host)
        loopback = origin.hostname == "localhost" or (
            origin.scheme == "http" and ip_address(origin.hostname or "").is_loopback
        )
        port = origin.port
    except ValueError:
        raise ConnectError("the Connect fallback must be a valid HTTPS origin") from None
    if (not origin.hostname or origin.username or origin.password or origin.query
            or origin.fragment or origin.path not in {"", "/"}
            or re.search(r"[\s?#@]", host)
            or not (origin.scheme == "https" or (origin.scheme == "http" and loopback))):
        raise ConnectError("the Connect fallback must be a valid HTTPS origin")
    primary = urllib.parse.urlsplit(primary_host)
    default_port = 443 if origin.scheme == "https" else 80
    if (origin.scheme, origin.hostname, port or default_port) == (
            primary.scheme, primary.hostname, primary.port or default_port):
        raise ConnectError("the Connect fallback must have a different origin from the primary")
    for credential in (client_id, client_secret):
        if not re.fullmatch(r"[!-~]+", credential) or credential != credential.strip("'\""):
            raise ConnectError("the Connect fallback has an invalid Access credential")
    return {"CF-Access-Client-Id": client_id, "CF-Access-Client-Secret": client_secret}


class Connect:
    def __init__(self, env_path, *, primary_only=False):
        values = read_env(env_path)
        self.host = values.get(HOST_KEY, "").rstrip("/")
        self._token = values.get(TOKEN_KEY, "")
        origin = urllib.parse.urlsplit(self.host)
        try:
            private = origin.hostname == "localhost" or ip_address(origin.hostname or "").is_private
        except ValueError:
            private = False
        if (not self._token or origin.username or origin.password or origin.query
                or origin.fragment or origin.path not in {"", "/"}
                or not (origin.scheme == "https" or (origin.scheme == "http" and private))):
            raise ConnectError("the Connect environment is invalid (https, or http on a private address, and a token)")
        self._primary_only = primary_only
        self._fallback = None
        if not primary_only and all(values.get(name) for name in FALLBACK_KEYS):
            self._fallback = tuple(values[name] for name in FALLBACK_KEYS)

    def raw(self, path, limit=2 * 1024 * 1024, method="GET", body=None, timeout=15.0):
        headers = {"Authorization": f"Bearer {self._token}"}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        if self._primary_only or self._fallback:
            # A proxy's connection or response cannot tell us whether the
            # primary Connect endpoint is reachable.
            try:
                return self._request(self.host, path, limit, method, data, headers, timeout,
                                     urllib.request.ProxyHandler({}), _PrimaryHTTPHandler, _PrimaryHTTPSHandler)
            except ConnectUnavailable as primary_error:
                if self._fallback is None:
                    raise
                host, client_id, client_secret = self._fallback
                try:
                    access_headers = fallback_headers(self.host, host, client_id, client_secret)
                except ConnectError as error:
                    print(f"WARNING: ignoring invalid Connect fallback: {error}", file=sys.stderr)
                    raise primary_error from None
                print("Connect primary is unreachable; trying the Connect fallback", file=sys.stderr)
                return self._request(host.rstrip("/"), path, limit, method, data, headers | access_headers, timeout,
                                     urllib.request.ProxyHandler({}))
        return self._request(self.host, path, limit, method, data, headers, timeout)

    @staticmethod
    def _request(host, path, limit, method, data, headers, timeout, *handlers):
        request = urllib.request.Request(f"{host}{path}", data=data, headers=headers, method=method)
        try:
            with urllib.request.build_opener(_NoRedirect, *handlers).open(request, timeout=timeout) as response:
                body = response.read(limit + 1)
        except urllib.error.HTTPError as error:
            kind = NotFound if error.code == 404 else ConnectError
            error.close()
            raise kind(f"Connect returned HTTP {error.code} for {path.split('?')[0]}") from None
        except (OSError, http.client.HTTPException):
            # Never echo the response: a malformed status line can carry its text.
            raise ConnectError(f"Connect at {host} is unreachable or answered malformed HTTP") from None
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

    def notes_titled(self, title):
        """(vault name, title) of every Secure Note titled exactly `title`,
        across the vaults this token can see."""
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
                        and item.get("title") == title):
                    found.append((str(vault.get("name", vault["id"])), item["title"]))
        return sorted(found)

    @staticmethod
    def _within(seconds, call):
        """Run `call` but give up after `seconds` of wall time, even if a slow
        response keeps each socket read under its own timeout."""
        outcome = {}
        def target():
            try:
                outcome["value"] = call()
            except BaseException as error:  # handed to the caller below
                outcome["error"] = error
        worker = threading.Thread(target=target, daemon=True)
        worker.start()
        worker.join(max(0.0, seconds))
        if worker.is_alive():
            raise ConnectError("Connect did not answer within the time left")
        if "error" in outcome:
            raise outcome["error"]
        return outcome["value"]

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
        # One note in all of 1Password, not one per vault: setup finds it by
        # title across every vault and refuses two.
        elsewhere = [v for v, _ in self.notes_titled(title) if v != vault]
        vault_name = next((str(v.get("name")) for v in self.get("/v1/vaults")
                           if isinstance(v, dict) and v.get("id") == vault_id), vault)
        elsewhere = [v for v in elsewhere if v != vault_name]
        if elsewhere:
            raise ConnectError(f"a '{title}' note also exists in vault {elsewhere[0]}; keep only the one in {vault_name}")
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
            try:
                stored = self._within(remaining, lambda: self.get(
                    f"/v1/vaults/{vault_id}/items/{item_id}", timeout=min(15.0, remaining)))
            except NotFound:
                # A just-created item 404s until Connect's copy has it.
                stored = None
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
