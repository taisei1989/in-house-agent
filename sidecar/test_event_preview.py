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
