"""Run with python -m sidecar.server. Bootstrap token arrives only on stdin."""
import argparse
import asyncio
from contextlib import asynccontextmanager, suppress
import hmac
import fcntl
import json
import logging
import os
from pathlib import Path
import socket
import subprocess
import sys
import uuid

import psutil
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
import uvicorn

from .backend import BackendConfig, ThreadedSDKBackend
from .cloud_proxy import register_secret, redact, RedactingFormatter

LOG = logging.getLogger("sidecar")


class ChatInput(BaseModel):
    prompt: str = Field(min_length=1, max_length=100000)
    workspace: str | None = None
    isolated: bool = False
    local_only: bool = False


class ApprovalInput(BaseModel):
    approved: bool


class Service:
    def __init__(self, config, token, backend_factory=ThreadedSDKBackend, lock_path=None):
        self.config, self.token = config, token
        self.status, self.error = "starting", None
        self.pending = {}
        self.events = None
        self.busy = False
        self.backend = backend_factory(config, self.approve)
        self.backend_factory = backend_factory
        self.server = None
        self.active_task = None
        self.lock_path = lock_path
        self.lock_file = None

    async def load(self):
        self.status = "loading_model"
        try:
            if self.lock_path:
                lock_path = Path(self.lock_path).expanduser()
                lock_path.parent.mkdir(parents=True, exist_ok=True)
                self.lock_file = lock_path.open("a")
                while True:
                    try:
                        fcntl.flock(self.lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        await asyncio.sleep(.5)
            await self.backend.start()
            self.status = "ready"
            LOG.info("Model ready")
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            self.status, self.error = "error", redact(exc)
            LOG.exception("Model startup failed")

    async def approve(self, call, reason=""):
        # Read-only tools remain usable for unattended routines; every other
        # operation requires an explicit, single-use UI response.
        name = getattr(call.name, "value", call.name)
        file_tools = {"view_file", "list_directory", "find_file", "search_directory", "create_file", "edit_file"}
        if name in file_tools:
            workspace = Path(self.config.workspace).expanduser().resolve()
            paths = [getattr(call, "canonical_path", None)]
            paths.extend(call.args.get(key) for key in ("path", "file_path", "directory_path", "TargetFile", "output_path"))
            for raw in paths:
                if not raw:
                    continue
                if not isinstance(raw, str) or "://" in raw:
                    return False
                target = Path(raw).expanduser()
                if not target.is_absolute():
                    target = workspace / target
                if not target.resolve().is_relative_to(workspace):
                    return False
        if name in {"view_file", "list_directory", "find_file", "search_directory", "finish"}:
            return True
        if self.events is None:
            return False
        identifier = str(uuid.uuid4())
        future = asyncio.get_running_loop().create_future()
        event = {"type": "approval", "id": identifier, "name": name, "args": call.args, "reason": reason}
        self.pending[identifier] = (event, future)
        await self.events.put(event)
        try:
            return await asyncio.wait_for(future, timeout=300)
        except (asyncio.TimeoutError, asyncio.CancelledError):
            return False
        finally:
            self.pending.pop(identifier, None)

    def deny_pending(self):
        for _, future in self.pending.values():
            if not future.done():
                future.set_result(False)

    async def reset_conversation(self):
        """Recreate the public SDK Agent instead of mutating private history."""
        try:
            await self.backend.close()
            self.backend = self.backend_factory(self.config, self.approve)
            await self.backend.start()
            self.error = None
            self.status = "ready"
        except asyncio.CancelledError:
            self.status = "error"
            self.error = "Conversation reset interrupted. Restart the server."
            raise
        except Exception as exc:
            self.status, self.error = "error", redact(exc)
            LOG.exception("Conversation reset failed")
        finally:
            self.busy = False
            self.active_task = None


def create_app(service):
    @asynccontextmanager
    async def lifespan(app):
        loading = asyncio.create_task(service.load())
        yield
        service.deny_pending()
        loading.cancel()
        with suppress(asyncio.CancelledError):
            await loading
        if service.active_task is not None:
            service.active_task.cancel()
            with suppress(asyncio.CancelledError, asyncio.TimeoutError):
                await asyncio.wait_for(service.active_task, timeout=3)
        try:
            await asyncio.wait_for(service.backend.close(), timeout=8)
        except Exception:
            LOG.exception("Backend shutdown failed")
        finally:
            if service.lock_file:
                service.lock_file.close()
                service.lock_file = None

    app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)

    @app.middleware("http")
    async def authenticate(request, call_next):
        # Native clients send no Origin. Reject browser-origin requests even if
        # they somehow acquire a token; no CORS access is provided.
        if request.headers.get("origin") is not None:
            from fastapi.responses import JSONResponse
            return JSONResponse({"detail": "Browser requests are not allowed"}, status_code=403)
        expected = "Bearer " + service.token
        if not hmac.compare_digest(request.headers.get("authorization", ""), expected):
            from fastapi.responses import JSONResponse
            return JSONResponse({"detail": "Unauthorized"}, status_code=401)
        return await call_next(request)

    @app.get("/health")
    async def health():
        process = psutil.Process()
        memory = process.memory_info().rss
        with suppress(psutil.Error, PermissionError):
            for child in process.children(recursive=True):
                with suppress(psutil.Error):
                    memory += child.memory_info().rss
        return {"status": service.status, "model": Path(service.config.model_path).name if service.config.backend == "litert" else service.config.model,
                "memory_bytes": memory, "error": service.error, "busy": service.busy,
                "workspace": service.config.workspace, "backend": service.config.backend}

    @app.get("/approvals")
    async def approvals():
        return [event for event, _ in service.pending.values()]

    @app.post("/conversations/reset", status_code=202)
    async def reset():
        if service.busy:
            raise HTTPException(409, "Wait for the active task to stop before resetting")
        if service.status != "ready":
            raise HTTPException(503, "Model is not ready")
        service.busy = True
        service.status = "loading_model"
        service.deny_pending()
        service.active_task = asyncio.create_task(service.reset_conversation())
        return {"status": "loading_model"}

    @app.post("/approvals/{identifier}")
    async def resolve(identifier: str, body: ApprovalInput):
        pending = service.pending.get(identifier)
        if pending is None or pending[1].done():
            raise HTTPException(404, "Approval expired or already answered")
        pending[1].set_result(body.approved)
        return {"accepted": True}

    @app.post("/chat")
    async def chat(body: ChatInput, request: Request):
        if body.local_only and service.config.backend != "litert":
            raise HTTPException(403, "Scheduled routines require the local LiteRT backend")
        if service.status != "ready":
            raise HTTPException(503, service.error or "Model is not ready")
        if service.busy:
            raise HTTPException(409, "Another chat is running")
        service.busy = True
        queue = asyncio.Queue()
        service.events = queue

        async def produce():
            try:
                target = Path(body.workspace or service.config.workspace).expanduser().resolve(strict=True)
                if body.isolated or str(target) != service.config.workspace:
                    if not target.is_dir():
                        raise ValueError("Workspace must be a directory")
                    service.status = "loading_model"
                    await service.backend.close()
                    service.config.workspace = str(target)
                    service.backend = service.backend_factory(service.config, service.approve)
                    await service.backend.start()
                    service.status = "ready"
                async for event in service.backend.stream(body.prompt):
                    await queue.put(event)
                await queue.put({"type": "done"})
            except asyncio.CancelledError:
                if service.status == "loading_model":
                    service.status = "error"
                    service.error = "Workspace change interrupted. Restart the server."
                raise
            except Exception as exc:
                if service.status == "loading_model":
                    service.status, service.error = "error", redact(exc)
                LOG.exception("Chat failed")
                await queue.put({"type": "error", "message": redact(exc)})

        async def stream():
            task = asyncio.create_task(produce())
            service.active_task = task
            try:
                while True:
                    if await request.is_disconnected():
                        break
                    try:
                        event = await asyncio.wait_for(queue.get(), timeout=1)
                    except asyncio.TimeoutError:
                        yield ": keepalive\n\n"
                        continue
                    yield "data: " + json.dumps(event, ensure_ascii=False) + "\n\n"
                    if event["type"] in {"done", "error"}:
                        break
            finally:
                service.events = None
                service.deny_pending()
                with suppress(Exception):
                    await asyncio.wait_for(service.backend.cancel(), timeout=3)
                task.cancel()
                try:
                    await asyncio.wait_for(task, timeout=3)
                except asyncio.CancelledError:
                    pass
                except asyncio.TimeoutError:
                    service.status = "error"
                    service.error = "Task cancellation timed out. Restart the server."
                if body.isolated:
                    # Retain busy across cleanup. A UI chat must never enter
                    # between a routine and clearing its private conversation.
                    service.status = "loading_model"
                    try:
                        await asyncio.wait_for(service.backend.close(), timeout=10)
                        service.backend = service.backend_factory(service.config, service.approve)
                        await service.backend.start()
                        service.status = "ready"
                    except asyncio.CancelledError:
                        service.status = "error"
                        service.error = "Routine cleanup interrupted. Restart the server."
                        raise
                    except Exception as exc:
                        service.status, service.error = "error", redact(exc)
                service.active_task = None
                service.busy = False
        return StreamingResponse(stream(), media_type="text/event-stream", headers={"Cache-Control": "no-cache"})

    @app.post("/shutdown")
    async def shutdown():
        service.deny_pending()
        if service.server:
            service.server.should_exit = True
        return {"stopping": True}
    return app


def stop_children():
    try:
        children = psutil.Process().children(recursive=True)
    except (psutil.Error, PermissionError):
        return
    for child in children:
        with suppress(psutil.Error):
            child.terminate()
    _, alive = psutil.wait_procs(children, timeout=3)
    for child in alive:
        with suppress(psutil.Error):
            child.kill()


async def run(args, token, bootstrap):
    backend = bootstrap.get("backend", "litert")
    allow_cloud = bootstrap.get("allow_cloud") is True
    api_key = bootstrap.get("api_key", "")
    model = bootstrap.get("model", "gemma4" if backend == "litert" else "")
    base_url = bootstrap.get("base_url", "http://127.0.0.1:11434/v1")
    if not all(isinstance(value, str) for value in (backend, api_key, model, base_url)):
        raise ValueError("Invalid bootstrap configuration")
    register_secret(token)
    register_secret(api_key)
    service = Service(BackendConfig(args.model, args.workspace, backend=backend, allow_cloud=allow_cloud,
                                   api_key=api_key, model=model, base_url=base_url), token, lock_path=args.lock_path)
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    sock.listen(128)
    server = uvicorn.Server(uvicorn.Config(create_app(service), log_level="info", access_log=False, timeout_graceful_shutdown=10))
    service.server = server
    print(json.dumps({"event": "listening", "port": sock.getsockname()[1]}), flush=True)

    async def watch_parent():
        while True:
            await asyncio.sleep(1)
            if args.parent_pid and os.getppid() != args.parent_pid:
                service.deny_pending()
                server.should_exit = True
                # A native model load can stall cleanup. Force bounded exit.
                await asyncio.sleep(12)
                stop_children()
                os._exit(0)
    watcher = asyncio.create_task(watch_parent())
    try:
        await server.serve(sockets=[sock])
    finally:
        watcher.cancel()
        sock.close()
        stop_children()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--parent-pid", type=int, default=0)
    parser.add_argument("--lock-path", default=str(Path.home() / "Library/Application Support/InHouseAgent/server.lock"))
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, stream=sys.stderr)
    bootstrap = json.loads(sys.stdin.readline())
    token = bootstrap.get("token", "")
    if not isinstance(token, str) or len(token) < 32:
        raise SystemExit("Bootstrap requires a random token of at least 32 characters")
    register_secret(token)
    register_secret(bootstrap.get("api_key", "") if isinstance(bootstrap.get("api_key", ""), str) else "")
    for handler in logging.getLogger().handlers:
        handler.setFormatter(RedactingFormatter("%(levelname)s:%(name)s:%(message)s"))
    if os.getpgrp() != os.getpid():
        os.setsid()
    guardian = subprocess.Popen([sys.executable, "-B", "-m", "sidecar.guardian", str(os.getpid())],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True)
    try:
        asyncio.run(run(args, token, bootstrap))
    finally:
        stop_children()
        with suppress(Exception):
            guardian.wait(timeout=4)


if __name__ == "__main__":
    main()
