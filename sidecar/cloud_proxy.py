"""Narrow authenticated bridge for SDK versions without OpenAI API-key fields.

The public SDK's LocalOpenAIAgentConfig only accepts a base URL. This bridge
keeps the provider key in memory and puts an unguessable capability in that
loopback URL. It is not a general forward proxy and never follows redirects.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hmac
import logging
import secrets
import threading
from urllib.parse import urlsplit

import httpx


_secrets = set()


def register_secret(value):
    if value:
        _secrets.add(value)


def redact(value):
    text = str(value)
    for secret in sorted(_secrets, key=len, reverse=True):
        text = text.replace(secret, "<redacted>")
    return text


class RedactingFormatter(logging.Formatter):
    def format(self, record):
        return redact(super().format(record))


def validate_endpoint(base_url):
    parsed = urlsplit(base_url)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or parsed.query or parsed.fragment
            or any(char.isspace() for char in base_url)):
        raise ValueError("Cloud endpoint must be an HTTPS URL without credentials, query, or fragment")
    try:
        parsed.port
    except ValueError:
        raise ValueError("Invalid cloud endpoint port") from None
    return base_url.rstrip("/")


class OpenAICloudProxy:
    MAX_BODY = 8 * 1024 * 1024

    def __init__(self, base_url, api_key, *, transport=None):
        self.upstream = validate_endpoint(base_url) + "/chat/completions"
        if not api_key or any(char in api_key for char in "\r\n"):
            raise ValueError("A valid API key is required")
        self.api_key = api_key
        self.capability = secrets.token_urlsafe(32)
        register_secret(api_key)
        register_secret(self.capability)
        self.client = httpx.Client(transport=transport, follow_redirects=False, trust_env=False,
                                   timeout=httpx.Timeout(connect=15, read=180, write=30, pool=15))
        self.responses = set()
        self.lock = threading.Lock()
        self.stopping = threading.Event()
        proxy = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.0"

            def log_message(self, *args):
                pass  # Never log the capability URL, payload, or provider response.

            def reject(self, status):
                self.send_response(status)
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()

            def do_GET(self):
                self.reject(405)

            def do_OPTIONS(self):
                self.reject(403)

            def do_POST(self):
                if proxy.stopping.is_set():
                    self.reject(503)
                    return
                expected = "/" + proxy.capability + "/v1/chat/completions"
                if (self.headers.get("Origin") is not None
                        or not hmac.compare_digest(self.path, expected)):
                    self.reject(403)
                    return
                if self.headers.get("Transfer-Encoding") is not None:
                    self.reject(400)
                    return
                try:
                    length = int(self.headers.get("Content-Length", "-1"))
                except ValueError:
                    length = -1
                if not 0 < length <= proxy.MAX_BODY:
                    self.reject(413)
                    return
                self.connection.settimeout(30)
                try:
                    body = self.rfile.read(length)
                    if len(body) != length:
                        self.reject(400)
                        return
                    with proxy.client.stream("POST", proxy.upstream, content=body,
                            headers={"Authorization": "Bearer " + proxy.api_key,
                                     "Content-Type": "application/json", "Accept": "text/event-stream"}) as response:
                        with proxy.lock:
                            proxy.responses.add(response)
                        try:
                            # Provider error bodies/redirect locations may echo
                            # credentials or payloads. Do not forward them.
                            if response.status_code != 200:
                                self.reject(502)
                                return
                            self.send_response(200)
                            content_type = response.headers.get("content-type", "application/json")
                            self.send_header("Content-Type", "text/event-stream" if "text/event-stream" in content_type else "application/json")
                            self.send_header("Connection", "close")
                            self.send_header("Cache-Control", "no-store")
                            self.end_headers()
                            for chunk in response.iter_bytes():
                                if proxy.stopping.is_set():
                                    break
                                self.wfile.write(chunk)
                                self.wfile.flush()
                        finally:
                            with proxy.lock:
                                proxy.responses.discard(response)
                except (httpx.HTTPError, OSError, TimeoutError):
                    # Keep errors generic; exception URLs contain capability.
                    self.close_connection = True

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True, name="cloud-bridge")

    @property
    def base_url(self):
        return f"http://127.0.0.1:{self.server.server_port}/{self.capability}/v1"

    def start(self):
        self.thread.start()

    def cancel(self):
        with self.lock:
            responses = tuple(self.responses)
        for response in responses:
            try:
                response.close()
            except (httpx.HTTPError, OSError):
                pass

    def close(self):
        self.stopping.set()
        self.cancel()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        self.client.close()
