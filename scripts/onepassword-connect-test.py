"""Exercise Connect failover and credential caching through local sockets."""

import contextlib
import io
import json
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from onepassword_connect import Connect, ConnectError, NotFound


TOKEN = "test-bearer"
CLIENT_ID = "test-id"
CLIENT_SECRET = "test-secret"
VAULT = "a" * 26
ITEM = "b" * 26
ENV_SCRIPT = Path(__file__).with_name("onepassword-connect-env.py")


class ConnectTests(unittest.TestCase):
    def setUp(self):
        self.resources = contextlib.ExitStack()
        self.addCleanup(self.resources.close)
        self.env = Path(self.resources.enter_context(tempfile.TemporaryDirectory())) / "test.env"

    def server(self, status=200, payload=None, disconnect=False, delay=0, plaintext_sent=None):
        requests = []
        body = json.dumps(payload if payload is not None else [{"id": VAULT}]).encode()

        class Handler(BaseHTTPRequestHandler):
            def handle(self):
                if plaintext_sent is not None:
                    self.wfile.write(b"HTTP/1.0 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
                    plaintext_sent.set()
                else:
                    super().handle()

            def do_GET(self):
                requests.append((self.path, self.headers))
                if disconnect:
                    return
                if delay:
                    time.sleep(delay)
                with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                    self.send_response(status)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

            def log_message(self, *_args):
                pass

        server = self.resources.enter_context(HTTPServer(("127.0.0.1", 0), Handler))
        worker = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
        worker.start()
        self.addCleanup(worker.join)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}", requests

    def closed_port(self):
        # Keep the port reserved, with no listener to accept the connection.
        reservation = self.resources.enter_context(socket.socket())
        reservation.bind(("127.0.0.1", 0))
        return f"http://127.0.0.1:{reservation.getsockname()[1]}"

    def write_env(self, primary, fallback=None):
        text = f"OP_CONNECT_HOST={primary}\nOP_CONNECT_TOKEN={TOKEN}\n"
        if fallback:
            text += (
                f"OP_CONNECT_FALLBACK_HOST={fallback}\n"
                f"OP_CONNECT_FALLBACK_CF_ACCESS_CLIENT_ID={CLIENT_ID}\n"
                f"OP_CONNECT_FALLBACK_CF_ACCESS_CLIENT_SECRET={CLIENT_SECRET}\n"
            )
        self.env.touch(mode=0o600)
        self.env.write_text(text)

    def refresh(self, fallback, secret_field="client-secret"):
        return subprocess.run(
            [sys.executable, "-B", ENV_SCRIPT, self.env, "refresh", fallback,
             f"op://{VAULT}/{ITEM}/client-id", f"op://{VAULT}/{ITEM}/{secret_field}"],
            capture_output=True, text=True, check=True,
        )

    def assert_headers(self, request, *, fallback=False, token=TOKEN):
        _, headers = request
        self.assertEqual(headers.get("Authorization"), f"Bearer {token}")
        self.assertEqual(headers.get("CF-Access-Client-Id"), CLIENT_ID if fallback else None)
        self.assertEqual(headers.get("CF-Access-Client-Secret"), CLIENT_SECRET if fallback else None)

    def test_refused_primary_uses_fallback(self):
        fallback, requests = self.server()
        self.write_env(self.closed_port(), fallback)
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(Connect(self.env).vault_count(), 1)
        self.assertEqual(len(stderr.getvalue().splitlines()), 1)
        self.assertIn("fallback", stderr.getvalue())
        self.assertEqual([path for path, _ in requests], ["/v1/vaults"])
        self.assert_headers(requests[0], fallback=True)

    def test_malformed_fallback_allows_healthy_primary(self):
        primary, requests = self.server()
        self.write_env(primary, "ftp://example.invalid")
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(Connect(self.env).vault_count(), 1)
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual([path for path, _ in requests], ["/v1/vaults"])
        self.assert_headers(requests[0])

    def test_malformed_fallback_warns_when_primary_is_unreachable(self):
        self.write_env(self.closed_port(), "ftp://example.invalid")
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            with self.assertRaisesRegex(ConnectError, "primary is unreachable"):
                Connect(self.env).vault_count()
        self.assertEqual(len(stderr.getvalue().splitlines()), 1)
        self.assertRegex(stderr.getvalue(), r"WARNING: .*fallback")

    def test_http_errors_are_final(self):
        fallback, fallback_requests = self.server()
        for status, error in ((401, ConnectError), (404, NotFound), (500, ConnectError)):
            with self.subTest(status=status):
                primary, requests = self.server(status)
                self.write_env(primary, fallback)
                with self.assertRaisesRegex(error, f"HTTP {status}"):
                    Connect(self.env).vault_count()
                self.assertEqual(len(requests), 1)
                self.assert_headers(requests[0])
        self.assertEqual(fallback_requests, [])

    def test_disconnect_after_request_is_final(self):
        primary, requests = self.server(disconnect=True)
        fallback, fallback_requests = self.server()
        self.write_env(primary, fallback)
        with self.assertRaises(ConnectError):
            Connect(self.env).vault_count()
        self.assertEqual(len(requests), 1)
        self.assert_headers(requests[0])
        self.assertEqual(fallback_requests, [])

    def test_connected_primary_read_timeout_is_final(self):
        primary, requests = self.server(delay=1)
        fallback, fallback_requests = self.server()
        self.write_env(primary, fallback)
        with self.assertRaises(ConnectError):
            Connect(self.env).get("/v1/vaults", timeout=0.5)
        self.assertEqual([path for path, _ in requests], ["/v1/vaults"])
        self.assertEqual(fallback_requests, [])

    def test_primary_tls_error_is_final(self):
        plaintext_sent = threading.Event()
        primary, _ = self.server(plaintext_sent=plaintext_sent)
        fallback, fallback_requests = self.server()
        self.write_env(primary.replace("http:", "https:"), fallback)
        with self.assertRaises(ConnectError):
            Connect(self.env).get("/v1/vaults", timeout=5)
        self.assertTrue(plaintext_sent.wait(5))
        self.assertEqual(fallback_requests, [])

    def test_tcp_connect_budget_does_not_limit_response_reads(self):
        primary, _ = self.server(delay=2.25)
        fallback, fallback_requests = self.server()
        self.write_env(primary, fallback)
        address = ("127.0.0.1", int(primary.rsplit(":", 1)[1]))
        connect_timeouts = []
        observing = True

        def observe_connect(event, args):
            # Observe the timeout on the actual TCP socket without stubbing it.
            if observing and event == "socket.connect" and args[1] == address:
                connect_timeouts.append(args[0].gettimeout())

        sys.addaudithook(observe_connect)
        try:
            self.assertEqual(Connect(self.env).get("/v1/vaults", timeout=8), [{"id": VAULT}])
        finally:
            observing = False
        self.assertEqual(connect_timeouts, [2.0])
        self.assertEqual(fallback_requests, [])

    def test_legacy_cache_reports_connection_failure(self):
        self.write_env(self.closed_port())
        with contextlib.redirect_stderr(io.StringIO()) as stderr:
            with self.assertRaises(ConnectError):
                Connect(self.env).vault_count()
        self.assertEqual(stderr.getvalue(), "")

    def test_refresh_writes_both_fields_from_primary(self):
        primary, requests = self.server(payload={
            "id": ITEM, "vault": {"id": VAULT}, "fields": [
                {"label": "client-id", "value": CLIENT_ID},
                {"label": "client-secret", "value": CLIENT_SECRET},
            ],
        })
        fallback, fallback_requests = self.server()
        self.write_env(primary)
        self.refresh(fallback)
        self.assertEqual(self.env.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.env.read_text().splitlines(), [
            f"OP_CONNECT_HOST={primary}",
            f"OP_CONNECT_TOKEN={TOKEN}",
            f"OP_CONNECT_FALLBACK_HOST={fallback}",
            f"OP_CONNECT_FALLBACK_CF_ACCESS_CLIENT_ID={CLIENT_ID}",
            f"OP_CONNECT_FALLBACK_CF_ACCESS_CLIENT_SECRET={CLIENT_SECRET}",
        ])
        self.assertEqual([path for path, _ in requests], [f"/v1/vaults/{VAULT}/items/{ITEM}"])
        self.assert_headers(requests[0])
        self.assertEqual(fallback_requests, [])

    def test_refresh_keeps_cache_when_primary_is_unreachable(self):
        fallback, requests = self.server()
        self.write_env(self.closed_port(), fallback)
        before = self.env.read_bytes()
        result = self.refresh(self.closed_port())
        self.assertIn("unreachable", result.stderr)
        self.assertEqual(self.env.read_bytes(), before)
        self.assertEqual(requests, [])

    def test_refresh_http_error_warns_and_preserves_cache(self):
        primary, requests = self.server(403)
        fallback, fallback_requests = self.server()
        self.write_env(primary, fallback)
        before = self.env.read_bytes()
        result = self.refresh(fallback)
        self.assertRegex(result.stderr, r"WARNING: .*HTTP 403")
        self.assertEqual(self.env.read_bytes(), before)
        self.assertEqual(len(requests), 1)
        self.assert_headers(requests[0])
        self.assertEqual(fallback_requests, [])

    def test_refresh_bad_reference_warns_and_preserves_cache(self):
        primary, requests = self.server()
        fallback, fallback_requests = self.server()
        self.write_env(primary, fallback)
        before = self.env.read_bytes()
        result = self.refresh(fallback, "client-secret?field=value")
        self.assertRegex(result.stderr, r"WARNING: .*reference")
        self.assertEqual(self.env.read_bytes(), before)
        self.assertEqual(requests, [])
        self.assertEqual(fallback_requests, [])

    def test_clear_fallback_preserves_primary(self):
        primary = self.closed_port()
        self.write_env(primary)
        primary_only = self.env.read_bytes()
        self.write_env(primary, self.closed_port())
        subprocess.run(
            [sys.executable, "-B", ENV_SCRIPT, self.env, "clear-fallback"],
            capture_output=True, text=True, check=True,
        )
        self.assertEqual(self.env.read_bytes(), primary_only)
        self.assertEqual(self.env.stat().st_mode & 0o777, 0o600)

    def test_replace_token_preserves_cached_fallback(self):
        primary, requests = self.server()
        fallback, fallback_requests = self.server()
        self.write_env(primary, fallback)
        token_file = self.env.with_name("token")
        token_file.touch(mode=0o600)
        token_file.write_text("new-test-bearer\n")
        subprocess.run(
            [sys.executable, "-B", ENV_SCRIPT, self.env, "replace-token", primary, token_file],
            capture_output=True, text=True, check=True,
        )
        self.assertEqual(len(requests), 1)
        self.assert_headers(requests[0], token="new-test-bearer")
        self.assertEqual(fallback_requests, [])
        self.assertEqual(self.env.read_text().splitlines()[1:], [
            "OP_CONNECT_TOKEN=new-test-bearer",
            f"OP_CONNECT_FALLBACK_HOST={fallback}",
            f"OP_CONNECT_FALLBACK_CF_ACCESS_CLIENT_ID={CLIENT_ID}",
            f"OP_CONNECT_FALLBACK_CF_ACCESS_CLIENT_SECRET={CLIENT_SECRET}",
        ])


if __name__ == "__main__":
    unittest.main(verbosity=2)
