"""Cloud contract tests. Mock transport is not live-provider verification."""
import asyncio
from pathlib import Path

import httpx
import pytest

from .backend import BackendConfig, SDKBackend
from .cloud_proxy import OpenAICloudProxy, redact, validate_endpoint


@pytest.mark.parametrize("url", ["http://api.example/v1", "https://user:key@api.example/v1", "https://api.example/v1?key=secret", "https://api.example/v1#secret"])
def test_cloud_endpoint_rejects_unsafe_urls(url):
    with pytest.raises(ValueError):
        validate_endpoint(url)


def test_proxy_scopes_route_auth_and_strips_provider_errors():
    requests = []
    def upstream(request):
        requests.append(request)
        assert request.headers["authorization"] == "Bearer fixture-api-key"
        assert str(request.url) == "https://provider.invalid/v1/chat/completions"
        return httpx.Response(200, headers={"content-type": "text/event-stream"}, content=b'data: {"choices":[]}\n\ndata: [DONE]\n\n')
    proxy = OpenAICloudProxy("https://provider.invalid/v1", "fixture-api-key", transport=httpx.MockTransport(upstream))
    proxy.start()
    try:
        with httpx.Client(trust_env=False) as client:
            endpoint = proxy.base_url + "/chat/completions"
            assert client.post(endpoint, headers={"Origin": "https://bad.invalid"}, json={}).status_code == 403
            assert client.post(proxy.base_url + "/other", json={}).status_code == 403
            assert client.post(endpoint.replace(proxy.capability, "wrong"), json={}).status_code == 403
            assert not requests
            response = client.post(endpoint, json={"model": "fixture", "messages": [], "stream": True})
            assert response.status_code == 200
            assert "[DONE]" in response.text
            assert len(requests) == 1
            assert "fixture-api-key" not in str(response.headers)
            assert proxy.capability not in redact(proxy.base_url)
    finally:
        proxy.close()


def test_proxy_does_not_follow_redirect_or_forward_error_body():
    requests = []
    def upstream(request):
        requests.append(request)
        return httpx.Response(302, headers={"location": "https://attacker.invalid"}, content=b"fixture-api-key")
    proxy = OpenAICloudProxy("https://provider.invalid/v1", "fixture-api-key", transport=httpx.MockTransport(upstream))
    proxy.start()
    try:
        with httpx.Client(trust_env=False) as client:
            response = client.post(proxy.base_url + "/chat/completions", json={})
            assert response.status_code == 502
            assert response.content == b""
            assert "location" not in response.headers
        assert len(requests) == 1
    finally:
        proxy.close()


@pytest.mark.asyncio
async def test_google_explicit_api_key_uses_sdk_endpoint_and_never_falls_back(monkeypatch, tmp_path):
    import google.antigravity
    captured = []
    class Agent:
        def __init__(self, config): captured.append(config)
        async def __aenter__(self): pass
        async def __aexit__(self, *args): pass
    monkeypatch.setattr(google.antigravity, "Agent", Agent)
    config = BackendConfig("unused", str(tmp_path), backend="google", model="fixture-model", api_key="fixture-key", allow_cloud=False)
    backend = SDKBackend(config, lambda call: False)
    with pytest.raises(ValueError, match="explicit cloud permission"):
        await backend.start()
    assert not captured
    config.allow_cloud = True
    await backend.start()
    assert type(captured[0]).__name__ == "LocalAgentConfig"
    assert captured[0].models[0].name == "fixture-model"
    assert captured[0].models[0].endpoint.api_key == "fixture-key"
    assert captured[0].vertex is False
    assert "fixture-key" not in repr(config)
    await backend.close()


@pytest.mark.asyncio
async def test_remote_openai_is_rejected_without_cloud_permission(tmp_path):
    config = BackendConfig("unused", str(tmp_path), backend="openai", base_url="https://provider.invalid/v1", model="fixture")
    with pytest.raises(ValueError, match="explicit cloud permission"):
        await SDKBackend(config, lambda call: False).start()


def test_actual_sdk_stderr_reader_passes_through_redacting_formatter():
    from collections import deque
    from io import BytesIO, StringIO
    import logging
    from types import SimpleNamespace
    from google.antigravity.connections.local.local_connection import LocalConnection
    from .cloud_proxy import RedactingFormatter, register_secret
    capability = "fixture-capability-for-stderr-test"
    key = "fixture-provider-key-for-stderr-test"
    register_secret(capability)
    register_secret(key)
    output = StringIO()
    handler = logging.StreamHandler(output)
    handler.setFormatter(RedactingFormatter("%(message)s"))
    root = logging.getLogger()
    previous_level = root.level
    root.setLevel(logging.INFO)
    root.addHandler(handler)
    try:
        connection = SimpleNamespace(_stderr_lines=deque(maxlen=100))
        stream = BytesIO(f"request failed at http://127.0.0.1:1234/{capability}/v1 with {key}\n".encode())
        LocalConnection._start_stderr_reader(connection, stream)
        connection._stderr_thread.join(timeout=2)
        assert not connection._stderr_thread.is_alive()
        rendered = output.getvalue()
        assert "harness stderr" in rendered
        assert "<redacted>" in rendered
        assert capability not in rendered
        assert key not in rendered
    finally:
        root.removeHandler(handler)
        root.setLevel(previous_level)
