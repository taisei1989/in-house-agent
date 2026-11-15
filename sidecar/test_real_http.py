"""Opt-in real Gemma / production sidecar HTTP verification (not a UI test).

python -m sidecar.test_real_http --execute --model /path/to/model.litertlm
Creates only isolated temporary fixtures. Never prints or saves its session token.
"""
import argparse
from contextlib import suppress
import json
import os
from pathlib import Path
import secrets
import selectors
import subprocess
import sys
import tempfile
import time

import httpx
import psutil

from .test_routine_integration import active_model_processes


def verify(args):
    if active_model_processes():
        raise RuntimeError("Another model task is active. Coordinate exclusive access first.")
    model = Path(args.model).expanduser().resolve(strict=True)
    root = Path(tempfile.mkdtemp(prefix="inhouse-http-verification-"))
    workspace = root / "workspace"
    workspace.mkdir()
    for name in ("alpha.txt", "beta.md"):
        (workspace / name).write_text("HTTP verification fixture\n")
    token = secrets.token_hex(32)
    evidence = {"ui_verified": False, "workspace": str(workspace), "checks": []}
    owned = {}
    base = None
    process = None
    stdout = None
    client = httpx.Client(trust_env=False, timeout=httpx.Timeout(15, read=30))

    def check(name, **details):
        item = {"name": name, **details}
        evidence["checks"].append(item)
        print(json.dumps(item), flush=True)

    def observe_processes():
        if process:
            with suppress(psutil.Error):
                owner = psutil.Process(process.pid)
                for child in [owner, *owner.children(recursive=True)]:
                    owned[(child.pid, child.create_time())] = child

    def call(path, body=None):
        return client.request("POST" if body is not None else "GET", base + path,
                              headers={"Authorization": "Bearer " + token}, json=body)

    def chat(prompt, approval=None, target=None):
        counters = {"token_events": 0, "thought_events": 0, "thought_characters": 0,
                    "thought_truncated": False, "approvals": 0, "tool_completed": [], "done": False}
        text = []
        deadline = time.monotonic() + args.turn_timeout
        with client.stream("POST", base + "/chat", headers={"Authorization": "Bearer " + token},
                           json={"prompt": prompt, "workspace": str(workspace)}) as response:
            response.raise_for_status()
            for line in response.iter_lines():
                if time.monotonic() > deadline:
                    raise TimeoutError("Real model chat exceeded the turn timeout")
                observe_processes()
                if not line.startswith("data: "):
                    continue
                event = json.loads(line[6:])
                kind = event["type"]
                if kind == "token":
                    if event["text"]:
                        counters["token_events"] += 1
                        text.append(event["text"])
                elif kind == "thought":
                    assert "signature" not in event
                    counters["thought_events"] += 1
                    counters["thought_characters"] += len(event.get("text", ""))
                    counters["thought_truncated"] = counters["thought_truncated"] or event.get("truncated", False)
                    assert counters["thought_characters"] <= 16384
                elif kind == "tool" and event.get("status") == "completed":
                    counters["tool_completed"].append(event["name"])
                elif kind == "approval":
                    counters["approvals"] += 1
                    if target is None or target.exists():
                        call("/approvals/" + event["id"], {"approved": False})
                        raise AssertionError("Approval was unexpected or the file existed before approval")
                    allowed = approval is True and event["name"] == "create_file"
                    if allowed:
                        values = [str(value) for value in event.get("args", {}).values()]
                        if not any(target.name in value for value in values):
                            allowed = False
                    accepted = call("/approvals/" + event["id"], {"approved": allowed})
                    accepted.raise_for_status()
                    if approval is True and not allowed:
                        raise AssertionError("Model requested an unexpected operation instead of the intended file creation")
                elif kind == "error":
                    raise RuntimeError("Production sidecar returned an error; inspect its isolated log")
                elif kind == "done":
                    counters["done"] = True
        if not counters["done"]:
            raise AssertionError("Stream did not deliver a completion event")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if not call("/health").json().get("busy"):
                break
            time.sleep(.1)
        else:
            raise TimeoutError("Completed request did not release the server")
        return "".join(text), counters

    try:
        with (root / "server.log").open("w") as log:
            process = subprocess.Popen([sys.executable, "-u", "-m", "sidecar.server", "--model", str(model),
                "--workspace", str(workspace), "--parent-pid", str(os.getpid()),
                "--lock-path", str(root / "server.lock")], cwd=str(Path(__file__).resolve().parent.parent),
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
            process.stdin.write(json.dumps({"token": token, "backend": "litert", "allow_cloud": False}) + "\n")
            process.stdin.flush()
            process.stdin.close()
            stdout = process.stdout
            with selectors.DefaultSelector() as selector:
                selector.register(stdout, selectors.EVENT_READ)
                if not selector.select(timeout=30):
                    raise TimeoutError("Production sidecar did not publish its dynamic port")
                bootstrap = json.loads(stdout.readline())
            if bootstrap.get("event") != "listening":
                raise AssertionError("Unexpected bootstrap event")
            base = "http://127.0.0.1:" + str(int(bootstrap["port"]))
            assert client.get(base + "/health").status_code == 401
            deadline = time.monotonic() + args.load_timeout
            states = set()
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError("Production sidecar exited during startup")
                observe_processes()
                try:
                    response = call("/health")
                    response.raise_for_status()
                    health = response.json()
                    states.add(health["status"])
                    if health["status"] == "ready":
                        break
                    if health["status"] == "error":
                        raise RuntimeError("Model startup failed; inspect isolated server log")
                except httpx.ConnectError:
                    pass
                time.sleep(.5)
            else:
                raise TimeoutError("Real model failed to become ready")
            check("health", states=sorted(states), authenticated=True, memory_bytes=health["memory_bytes"])
            text, stats = chat("Use list_directory to list all files in the current workspace. Return the exact file names.")
            assert all(name in text for name in ("alpha.txt", "beta.md")), "Known fixtures missing from real response"
            assert stats["token_events"] >= 2, "Response did not stream multiple nonempty token events"
            assert "list_directory" in stats["tool_completed"], "No genuine tool completion event"
            check("real_http_stream", **stats, expected_files=True)
            denied = workspace / "denied.txt"
            _, stats = chat("Use create_file to create denied.txt in the workspace with exactly DENIED_TEST followed by a newline. Do not run commands. If permission is denied, stop without retrying.", approval=False, target=denied)
            assert stats["approvals"] >= 1, "No execution-before-write approval event"
            assert not denied.exists(), "Denied file creation had a side effect"
            check("denied_write", **stats, file_absent=True)
            approved = workspace / "approved.txt"
            _, stats = chat("Use create_file to create approved.txt in the workspace with exactly APPROVAL_VERIFIED followed by a newline. Do not run commands. Wait for approval before creating it.", approval=True, target=approved)
            assert stats["approvals"] >= 1, "No approval event for file creation"
            assert approved.read_text() == "APPROVAL_VERIFIED\n", "Approved file content did not match"
            check("approved_write", **stats, exact_content=True)
            call("/shutdown", {}).raise_for_status()
            process.wait(timeout=25)
            assert process.returncode == 0, "Sidecar shutdown failed"
            check("shutdown", exit_code=process.returncode)
    except BaseException as exc:
        evidence["error"] = type(exc).__name__ + ": " + str(exc)
        raise
    finally:
        if base and process and process.poll() is None:
            with suppress(Exception):
                call("/shutdown", {})
            try:
                process.wait(timeout=25)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        client.close()
        if stdout:
            stdout.close()
        deadline = time.monotonic() + 20
        alive = []
        while time.monotonic() < deadline:
            alive = []
            for (pid, born), child in owned.items():
                with suppress(psutil.Error):
                    if child.is_running() and child.create_time() == born and child.status() != psutil.STATUS_ZOMBIE:
                        alive.append({"pid": pid, "name": child.name()})
            if not alive:
                break
            time.sleep(.5)
        evidence["remaining_owned_processes"] = alive
        (root / "evidence.json").write_text(json.dumps(evidence, indent=2))
        print(json.dumps({"evidence": str(root / "evidence.json"), "remaining_owned_processes": alive,
                          "ui_verified": False}), flush=True)
    if alive:
        raise AssertionError("Owned model processes remain after shutdown")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--model", required=True)
    parser.add_argument("--load-timeout", type=float, default=600)
    parser.add_argument("--turn-timeout", type=float, default=600)
    args = parser.parse_args()
    if not args.execute:
        parser.error("--execute is required to load and run the real model")
    verify(args)
