"""Protocol tests use a test double; they do not certify model inference."""
import asyncio
from types import SimpleNamespace
from fastapi.testclient import TestClient
import pytest
from .backend import BackendConfig
from .server import Service, create_app, ChatInput


class TestBackend:
    __test__ = False
    def __init__(self, config, approve):
        self.approve = approve
    async def start(self): pass
    async def cancel(self): pass
    async def close(self): pass
    async def stream(self, prompt):
        yield {"type": "token", "text": "こんにちは\n"}


def make_service():
    return Service(BackendConfig("/not-a-real-model", "/tmp"), "a" * 64, TestBackend)


def test_auth_health_and_sse():
    service = make_service()
    with TestClient(create_app(service)) as client:
        assert client.get("/health").status_code == 401
        headers = {"Authorization": "Bearer " + service.token}
        assert client.get("/health", headers={**headers, "Origin": "https://attacker.invalid"}).status_code == 403
        health = client.get("/health", headers=headers).json()
        assert health["status"] == "ready"
        assert health["memory_bytes"] > 0
        assert health["backend"] == "litert"
        response = client.post("/chat", json={"prompt": "hello"}, headers=headers)
        assert response.status_code == 200
        assert '"type": "token"' in response.text
        assert '"type": "done"' in response.text
        assert not service.busy
        assert client.post("/approvals/stale", json={"approved": True}, headers=headers).status_code == 404
        response = client.post("/chat", json={"prompt": "hello", "workspace": "/private/tmp"}, headers=headers)
        assert response.status_code == 200
        assert service.config.workspace == "/private/tmp"


@pytest.mark.asyncio
async def test_write_cannot_execute_until_approval_and_disconnect_denies():
    service = make_service()
    service.events = asyncio.Queue()
    call = SimpleNamespace(name="create_file", args={"path": "/tmp/test", "content": "test"})
    pending = asyncio.create_task(service.approve(call))
    event = await service.events.get()
    assert event["type"] == "approval"
    assert not pending.done()
    service.pending[event["id"]][1].set_result(True)
    assert await pending is True
    assert not service.pending
    second = asyncio.create_task(service.approve(call))
    await service.events.get()
    service.deny_pending()
    assert await second is False
    service.events = None
    assert await service.approve(call) is False


@pytest.mark.asyncio
async def test_read_only_operation_does_not_require_ui():
    service = make_service()
    assert await service.approve(SimpleNamespace(name="list_directory", args={})) is True
    assert await service.approve(SimpleNamespace(name="unknown_tool", args={})) is False


@pytest.mark.asyncio
async def test_workspace_escape_is_denied_before_approval(tmp_path):
    service = make_service()
    service.config.workspace = str(tmp_path)
    service.events = asyncio.Queue()
    for name in ["view_file", "create_file", "edit_file"]:
        assert await service.approve(SimpleNamespace(name=name, args={"path": "../outside"})) is False
    (tmp_path / "escape").symlink_to("/etc")
    assert await service.approve(SimpleNamespace(name="view_file", args={"path": "escape/passwd"})) is False
    assert service.events.empty()


@pytest.mark.asyncio
async def test_stream_disconnect_denies_pending_write():
    effects = []
    class ApprovalBackend(TestBackend):
        async def stream(self, prompt):
            approved = await self.approve(SimpleNamespace(name="create_file", args={"path": "/tmp/test"}))
            if approved:
                effects.append("write")
            yield {"type": "token", "text": "finished"}
    service = Service(BackendConfig("unused", "/tmp"), "a" * 64, ApprovalBackend)
    service.status = "ready"
    app = create_app(service)
    endpoint = next(r.endpoint for r in app.routes if r.path == "/chat")
    class Request:
        async def is_disconnected(self): return False
    response = await endpoint(ChatInput(prompt="write"), Request())
    first = await anext(response.body_iterator)
    assert '"type": "approval"' in first
    await response.body_iterator.aclose()
    assert not effects
    assert not service.pending
    assert not service.busy


@pytest.mark.asyncio
async def test_workspace_loading_disconnect_marks_error():
    started = asyncio.Event()
    class SlowBackend(TestBackend):
        async def start(self):
            started.set()
            await asyncio.Event().wait()
    service = Service(BackendConfig("unused", "/tmp"), "a" * 64, SlowBackend)
    service.status = "ready"
    endpoint = next(r.endpoint for r in create_app(service).routes if r.path == "/chat")
    class Request:
        async def is_disconnected(self): return False
    response = await endpoint(ChatInput(prompt="hi", workspace="/private/tmp"), Request())
    iterator = response.body_iterator
    first = asyncio.create_task(anext(iterator))
    await started.wait()
    first.cancel()
    with pytest.raises(asyncio.CancelledError):
        await first
    assert service.status == "error"
    assert not service.busy


@pytest.mark.asyncio
async def test_instance_lock_prevents_two_model_loads(tmp_path):
    lock_path = tmp_path / "server.lock"
    a = Service(BackendConfig("unused", "/tmp"), "a" * 64, TestBackend, lock_path)
    b = Service(BackendConfig("unused", "/tmp"), "b" * 64, TestBackend, lock_path)
    await a.load()
    waiting = asyncio.create_task(b.load())
    await asyncio.sleep(.05)
    assert a.status == "ready"
    assert b.status == "loading_model"
    a.lock_file.close()
    await asyncio.wait_for(waiting, timeout=2)
    assert b.status == "ready"
    b.lock_file.close()


def test_real_sdk_configuration_accepts_exact_tool_names():
    from google.antigravity import LiteRTAgentConfig, CapabilitiesConfig
    from google.antigravity.hooks import policy
    config = LiteRTAgentConfig(model_path="/tmp/no-model", workspaces=["/tmp"],
        capabilities=CapabilitiesConfig(enabled_tools=["list_directory", "create_file", "edit_file", "run_command", "finish"]),
        policies=[policy.ask_user("*", handler=lambda call: False)]).lightweight()
    assert {t.value for t in config.capabilities.enabled_tools} == {"list_directory", "create_file", "edit_file", "run_command", "finish"}


@pytest.mark.asyncio
async def test_reset_creates_new_backend_and_rejects_active_chat():
    service = make_service()
    service.status = "ready"
    original = service.backend
    endpoint = next(r.endpoint for r in create_app(service).routes if r.path == "/conversations/reset")
    service.busy = True
    from fastapi import HTTPException
    with pytest.raises(HTTPException) as error:
        await endpoint()
    assert error.value.status_code == 409
    assert service.backend is original
    service.busy = False
    assert await endpoint() == {"status": "loading_model"}
    task = service.active_task
    await task
    assert service.backend is not original
    assert service.status == "ready"
    assert not service.busy


@pytest.mark.asyncio
async def test_tool_completion_hook_results_are_not_guessed_or_duplicated():
    from google.antigravity.types import Text, ToolCall, ToolResult
    from .backend import SDKBackend
    backend = SDKBackend(BackendConfig("unused", "/tmp"), lambda call: False)
    result = ToolResult(name="list_directory", id="call-1", result=["a"])
    class Response:
        @property
        def chunks(self):
            async def events():
                yield ToolCall(name="list_directory", id="call-1")
                backend.tool_results.append(result)
                yield Text(step_index=1, text="a")
                yield result
            return events()
    class Agent:
        async def chat(self, prompt): return Response()
    backend.agent = Agent()
    events = [event async for event in backend.stream("list files")]
    assert [event["status"] for event in events if event["type"] == "tool"] == ["running", "completed"]


@pytest.mark.asyncio
async def test_isolated_routine_has_fresh_history_and_cleans_before_unlock():
    instances = []
    class HistoryBackend(TestBackend):
        def __init__(self, config, approve):
            super().__init__(config, approve)
            self.history = []
            instances.append(self)
        async def stream(self, prompt):
            self.history.append(prompt)
            yield {"type": "token", "text": ",".join(self.history)}
    service = Service(BackendConfig("unused", "/private/tmp"), "a" * 64, HistoryBackend)
    service.status = "ready"
    service.backend.history.append("private interactive history")
    endpoint = next(r.endpoint for r in create_app(service).routes if r.path == "/chat")
    class Request:
        async def is_disconnected(self): return False
    response = await endpoint(ChatInput(prompt="routine", isolated=True), Request())
    output = [line async for line in response.body_iterator]
    assert "private interactive history" not in "".join(output)
    assert len(instances) == 3
    assert service.backend.history == []
    assert not service.busy
    assert service.status == "ready"


def test_scheduled_routine_cannot_send_to_cloud_backend():
    service = make_service()
    service.config.backend = "google"
    service.config.model = "fixture-cloud-model"
    with TestClient(create_app(service)) as client:
        headers = {"Authorization": "Bearer " + service.token}
        health = client.get("/health", headers=headers).json()
        assert health["backend"] == "google"
        assert health["model"] == "fixture-cloud-model"
        result = client.post("/chat", headers=headers, json={"prompt": "private routine", "local_only": True})
        assert result.status_code == 403
        assert not service.busy
