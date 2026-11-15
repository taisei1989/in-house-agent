"""SDK adapter. No model emulation or implicit cloud fallback."""
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable
import asyncio
import threading
import json
from .cloud_proxy import OpenAICloudProxy, register_secret, redact


def bounded_preview(value, limit=8192):
    """UI-only preview; never alter the actual SDK result or approval args."""
    from pydantic import BaseModel
    secret_keys = {"apikey", "authorization", "password", "passwd", "secret", "token",
                   "accesstoken", "refreshtoken", "privatekey", "credentials", "clientsecret"}
    budget = {"nodes": 32, "chars": limit, "truncated": False}

    def text(raw):
        clean = redact(raw)
        if len(clean) > budget["chars"]:
            clean = clean[:budget["chars"]]
            budget["truncated"] = True
        budget["chars"] -= len(clean)
        return clean

    def sanitize(item, depth=0):
        if depth > 4 or budget["nodes"] <= 0 or budget["chars"] <= 0:
            budget["truncated"] = True
            return "…"
        budget["nodes"] -= 1
        if isinstance(item, BaseModel):
            try:
                item = item.model_dump(mode="json")
            except Exception:
                budget["truncated"] = True
                return "<unavailable structured result>"
        if isinstance(item, str):
            return text(item)
        if item is None or isinstance(item, (bool, int, float)):
            return item
        if isinstance(item, dict):
            output = {}
            for key, child in item.items():
                if not isinstance(key, str):
                    budget["truncated"] = True
                    continue
                normalized = "".join(char for char in key.lower() if char.isalnum())
                if (normalized in secret_keys or any(word in normalized for word in ("password", "secret", "credential"))
                        or normalized.endswith(("apikey", "privatekey", "accesstoken", "refreshtoken"))):
                    continue
                if budget["nodes"] <= 0 or budget["chars"] <= 0:
                    budget["truncated"] = True
                    break
                output[text(key)] = sanitize(child, depth + 1)
            return output
        if isinstance(item, (list, tuple)):
            output = []
            for child in item:
                if budget["nodes"] <= 0 or budget["chars"] <= 0:
                    budget["truncated"] = True
                    break
                output.append(sanitize(child, depth + 1))
            return output
        budget["truncated"] = True
        return "<unsupported result value>"

    safe = sanitize(value)
    rendered = safe if isinstance(safe, str) else json.dumps(safe, ensure_ascii=False, indent=2)
    if len(rendered) > limit:
        rendered = rendered[:limit]
        budget["truncated"] = True
    return rendered, budget["truncated"]


@dataclass
class BackendConfig:
    model_path: str
    workspace: str
    backend: str = "litert"
    base_url: str = "http://127.0.0.1:11434/v1"
    model: str = "gemma4"
    app_data_dir: str | None = None
    allow_cloud: bool = False
    api_key: str = field(default="", repr=False)


class SDKBackend:
    def __init__(self, config: BackendConfig, approve: Callable):
        self.config = config
        self.approve = approve
        self.agent = None
        self.response = None
        self.tool_results = []
        self.cloud_proxy = None

    async def start(self):
        from google.antigravity import Agent, LiteRTAgentConfig, LocalOpenAIAgentConfig, LocalAgentConfig, CapabilitiesConfig
        from google.antigravity.hooks import policy, PostToolCallHook
        backend = self

        class ToolCompletionHook(PostToolCallHook):
            async def run(self, context, data):
                # Some local harness versions dispatch this hook without
                # yielding ToolResult in response.chunks. Preserve the real
                # execution outcome instead of guessing at turn completion.
                backend.tool_results.append(data)
        workspace = Path(self.config.workspace).expanduser().resolve(strict=True)
        if not workspace.is_dir():
            raise ValueError("Workspace must be a directory")
        # Explicitly limit the tool surface: no web, MCP, or delegated agents.
        capabilities = CapabilitiesConfig(enabled_tools=[
            "view_file", "list_directory", "find_file", "search_directory",
            "create_file", "edit_file", "run_command", "finish",
        ])
        common = dict(workspaces=[str(workspace)], capabilities=capabilities,
                      policies=[*policy.workspace_only([str(workspace)]), policy.ask_user("*", handler=self.approve)],
                      hooks=[ToolCompletionHook()],
                      app_data_dir=self.config.app_data_dir)
        if self.config.backend == "litert":
            model = Path(self.config.model_path).expanduser().resolve(strict=True)
            config = LiteRTAgentConfig(model_path=str(model), **common).lightweight()
        elif self.config.backend == "google":
            if not self.config.allow_cloud or not self.config.api_key or not self.config.model:
                raise ValueError("Google requires explicit cloud permission, model, and API key")
            register_secret(self.config.api_key)
            config = LocalAgentConfig(model=self.config.model, api_key=self.config.api_key, vertex=False, **common)
        elif self.config.backend == "openai":
            from urllib.parse import urlparse
            url = urlparse(self.config.base_url)
            if not self.config.model:
                raise ValueError("An OpenAI-compatible model name is required")
            if self.config.allow_cloud:
                self.cloud_proxy = OpenAICloudProxy(self.config.base_url, self.config.api_key)
                self.cloud_proxy.start()
                endpoint = self.cloud_proxy.base_url
            else:
                if url.hostname not in {"127.0.0.1", "localhost", "::1"} or url.scheme not in {"http", "https"}:
                    raise ValueError("Remote OpenAI endpoint requires explicit cloud permission")
                if url.username is not None or url.password is not None or url.query or url.fragment:
                    raise ValueError("Local endpoint must not contain credentials, query, or fragment")
                endpoint = self.config.base_url
            config = LocalOpenAIAgentConfig(model=self.config.model, base_url=endpoint, **common)
        else:
            raise ValueError("Unsupported backend")
        try:
            self.agent = Agent(config)
            await self.agent.__aenter__()
        except BaseException:
            if self.cloud_proxy:
                self.cloud_proxy.close()
                self.cloud_proxy = None
            raise

    async def stream(self, prompt):
        from google.antigravity.types import Text, Thought, ToolCall, ToolResult
        self.tool_results.clear()
        emitted = set()
        thought_remaining = 16 * 1024
        thought_truncation_sent = False

        def completed(result):
            identifier = result.id or result.step_id
            key = (identifier, str(result.name))
            if key in emitted:
                return None
            emitted.add(key)
            result_text, result_cut = bounded_preview(result.result) if result.result is not None else ("", False)
            error_text, error_cut = bounded_preview(result.error, max(0, 8192 - len(result_text))) if result.error else ("", False)
            return {"type": "tool", "id": identifier, "name": str(result.name),
                    "status": "error" if result.error else "completed", "result": result_text,
                    "error": error_text, "truncated": result_cut or error_cut}

        self.response = await self.agent.chat(prompt)
        try:
            async for chunk in self.response.chunks:
                while self.tool_results:
                    event = completed(self.tool_results.pop(0))
                    if event:
                        yield event
                if isinstance(chunk, Text):
                    yield {"type": "token", "text": redact(chunk.text)}
                elif isinstance(chunk, Thought):
                    # Only the SDK's public Thought.text; never signatures or
                    # non-public provider reasoning state. Do not log this.
                    value = redact(chunk.text)
                    if thought_remaining > 0:
                        clipped = value[:thought_remaining]
                        cut = len(value) > thought_remaining
                        thought_remaining -= len(clipped)
                        if clipped or cut:
                            yield {"type": "thought", "text": clipped, "truncated": cut}
                        thought_truncation_sent = cut
                    elif value and not thought_truncation_sent:
                        yield {"type": "thought", "text": "", "truncated": True}
                        thought_truncation_sent = True
                elif isinstance(chunk, ToolCall):
                    args, truncated = bounded_preview(chunk.args)
                    yield {"type": "tool", "id": chunk.id or chunk.step_id, "name": str(chunk.name),
                           "args": args, "status": "running", "truncated": truncated}
                elif isinstance(chunk, ToolResult):
                    event = completed(chunk)
                    if event:
                        yield event
            while self.tool_results:
                event = completed(self.tool_results.pop(0))
                if event:
                    yield event
        finally:
            self.response = None

    async def cancel(self):
        if self.response is not None:
            await self.response.cancel()
        if self.cloud_proxy:
            self.cloud_proxy.cancel()

    async def close(self):
        try:
            await self.cancel()
            if self.agent is not None:
                await self.agent.__aexit__(None, None, None)
                self.agent = None
        finally:
            if self.cloud_proxy:
                self.cloud_proxy.close()
                self.cloud_proxy = None


class ThreadedSDKBackend:
    """Keep blocking native model loading away from HTTP and parent monitoring."""
    def __init__(self, config, approve):
        self.config, self.approve = config, approve
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self.loop.run_forever, daemon=True, name="agent-sdk")
        self.thread.start()
        self.sdk = None

    async def submit(self, coroutine):
        return await asyncio.wrap_future(asyncio.run_coroutine_threadsafe(coroutine, self.loop))

    async def start(self):
        http_loop = asyncio.get_running_loop()
        async def approval(call, reason=""):
            return await asyncio.wrap_future(asyncio.run_coroutine_threadsafe(self.approve(call, reason), http_loop))
        self.sdk = SDKBackend(self.config, approval)
        await self.submit(self.sdk.start())

    async def stream(self, prompt):
        http_loop = asyncio.get_running_loop()
        queue = asyncio.Queue()
        async def produce():
            try:
                async for event in self.sdk.stream(prompt):
                    http_loop.call_soon_threadsafe(queue.put_nowait, event)
            except Exception as exc:
                http_loop.call_soon_threadsafe(queue.put_nowait, exc)
            finally:
                http_loop.call_soon_threadsafe(queue.put_nowait, None)
        future = asyncio.run_coroutine_threadsafe(produce(), self.loop)
        try:
            while True:
                event = await queue.get()
                if event is None:
                    break
                if isinstance(event, Exception):
                    raise event
                yield event
        finally:
            if not future.done():
                future.cancel()

    async def cancel(self):
        if self.sdk:
            await self.submit(self.sdk.cancel())

    async def close(self):
        try:
            if self.sdk:
                await self.submit(self.sdk.close())
        finally:
            self.loop.call_soon_threadsafe(self.loop.stop)
