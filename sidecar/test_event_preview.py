"""Bounded UI previews only; no model load and no recorded thought content."""
import json

import pytest

from .backend import BackendConfig, SDKBackend, bounded_preview
from .cloud_proxy import register_secret


def test_preview_limits_depth_elements_text_and_removes_secret_fields():
    register_secret("fixture-known-secret")
    preview, truncated = bounded_preview({"api_key": "must-not-appear", "Authorization": "must-not-appear",
        "nested": {"password": "must-not-appear", "safe": "fixture-known-secret"},
        "items": list(range(100)), "large": "z" * 20000})
    assert len(preview) <= 8192
    assert truncated
    assert "must-not-appear" not in preview
    assert "fixture-known-secret" not in preview
    assert "<redacted>" in preview
    nested = {"a": {"b": {"c": {"d": {"e": {"payload": "too-deep"}}}}}}
    preview, truncated = bounded_preview(nested)
    assert truncated and "too-deep" not in preview


@pytest.mark.asyncio
async def test_public_thought_text_is_capped_and_signature_not_forwarded():
    from google.antigravity.types import Thought, Text, ToolCall, ToolResult
    register_secret("fixture-thought-secret")
    backend = SDKBackend(BackendConfig("unused", "/tmp"), lambda call: False)
    class Response:
        @property
        def chunks(self):
            async def events():
                yield Thought(step_index=0, text="fixture-thought-secret", signature=b"private-signature")
                yield Thought(step_index=0, text="x" * 20000)
                yield Thought(step_index=0, text="y" * 20000)
                yield ToolCall(name="list_directory", id="tool-1", args={"path": "/tmp", "api_key": "never-forward"})
                yield ToolResult(name="list_directory", id="tool-1", result={"files": ["alpha.txt"], "token": "never-forward"})
                yield Text(step_index=1, text="answer")
            return events()
    class Agent:
        async def chat(self, prompt): return Response()
    backend.agent = Agent()
    output = [event async for event in backend.stream("fixture")]
    thoughts = [event for event in output if event["type"] == "thought"]
    assert sum(len(event["text"]) for event in thoughts) <= 16384
    assert any(event["truncated"] for event in thoughts)
    serialized = json.dumps(output)
    assert "signature" not in serialized
    assert "fixture-thought-secret" not in serialized
    assert "never-forward" not in serialized
    tools = [event for event in output if event["type"] == "tool"]
    assert isinstance(tools[0]["args"], str)
    assert isinstance(tools[1]["result"], str)
    assert "alpha.txt" in tools[1]["result"]


@pytest.mark.asyncio
@pytest.mark.parametrize("result_step", ["trajectory:1", None])
async def test_builtin_step_id_and_post_hook_call_id_share_one_activity(result_step):
    from google.antigravity.types import Text, ToolCall, ToolResult
    backend = SDKBackend(BackendConfig("unused", "/tmp"), lambda call: False)
    result = ToolResult(name="list_directory", id="call_123_0", step_id=result_step, result={"files": ["alpha.txt"]})
    class Response:
        @property
        def chunks(self):
            async def events():
                yield ToolCall(name="list_directory", id="trajectory:1", step_id="trajectory:1")
                backend.tool_results.append(result)
                yield Text(step_index=2, text="answer")
                # A later chunk may supply the native call id. It must not
                # create another row or downgrade the completed activity.
                yield ToolCall(name="list_directory", id="call_123_0", step_id="trajectory:1")
                yield result
            return events()
    class Agent:
        async def chat(self, prompt): return Response()
    backend.agent = Agent()
    events = [event async for event in backend.stream("fixture")]
    tools = [event for event in events if event["type"] == "tool"]
    assert [event["status"] for event in tools] == ["running", "completed"]
    assert {event["id"] for event in tools} == {"trajectory:1"}


@pytest.mark.asyncio
async def test_parallel_same_name_calls_are_not_guessed_by_name():
    from google.antigravity.types import ToolCall, ToolResult
    backend = SDKBackend(BackendConfig("unused", "/tmp"), lambda call: False)
    class Response:
        @property
        def chunks(self):
            async def events():
                yield ToolCall(name="list_directory", id="trajectory:1", step_id="trajectory:1")
                yield ToolCall(name="list_directory", id="trajectory:2", step_id="trajectory:2")
                yield ToolResult(name="list_directory", id="unmatched-call", result="result")
            return events()
    class Agent:
        async def chat(self, prompt): return Response()
    backend.agent = Agent()
    tools = [event async for event in backend.stream("fixture")]
    assert [event["id"] for event in tools] == ["trajectory:1", "trajectory:2", "unmatched-call"]


@pytest.mark.asyncio
@pytest.mark.parametrize("error", [None, "fixture execution error"])
async def test_post_hook_before_call_preserves_late_args_and_terminal_status(error):
    from google.antigravity.types import ToolCall, ToolResult
    backend = SDKBackend(BackendConfig("unused", "/tmp"), lambda call: False)
    class Response:
        @property
        def chunks(self):
            async def events():
                backend.tool_results.append(ToolResult(name="list_directory", id="native-call", step_id="trajectory:1",
                    result={"files": ["alpha.txt"]} if error is None else None, error=error))
                yield ToolCall(name="list_directory", id="trajectory:1", step_id="trajectory:1", args={"path": "/tmp/fixture"})
                yield ToolCall(name="list_directory", id="native-call", step_id="trajectory:1", args={"path": "/tmp/fixture"})
            return events()
    class Agent:
        async def chat(self, prompt): return Response()
    backend.agent = Agent()
    tools = [event async for event in backend.stream("fixture")]
    expected = "error" if error else "completed"
    assert len(tools) == 2
    assert {event["id"] for event in tools} == {"native-call"}
    assert all(event["status"] == expected for event in tools)
    assert "/tmp/fixture" in tools[-1]["args"]
    assert "result" not in tools[-1] and "error" not in tools[-1]
    # Merge exactly like the Swift UI: late metadata must not clear the result.
    row = {**tools[0], **tools[1]}
    assert row["status"] == expected
    if error:
        assert row["error"] == error
    else:
        assert "alpha.txt" in row["result"]
