"""Opt-in check that running bundled Python does not modify the signed app.

This exercises startup/error/shutdown, not model inference or GUI behavior.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import secrets
import selectors
import subprocess
import tempfile
import time
import urllib.request


def snapshot(root):
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in root.rglob("*") if path.is_file() and not path.is_symlink()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--python", type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.taisei1989.inhouseagent":
        raise SystemExit("Not the expected application")
    resources = app / "Contents/Resources"
    before = snapshot(app)
    token = secrets.token_hex(32)
    with tempfile.TemporaryDirectory(prefix="inhouse-bundle-check-") as folder:
        work = Path(folder)
        environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        with (work / "server.log").open("wb") as log:
            child = subprocess.Popen([
                str(args.python.absolute()), "-B", "-u", "-m", "sidecar.server",
                "--model", str(work / "intentionally-missing.litertlm"),
                "--workspace", str(work), "--parent-pid", str(os.getpid()),
                "--lock-path", str(work / "server.lock"),
            ], cwd=resources, env=environment, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=log)
            try:
                child.stdin.write(json.dumps({"token": token}).encode() + b"\n")
                child.stdin.close()
                with selectors.DefaultSelector() as selector:
                    selector.register(child.stdout, selectors.EVENT_READ)
                    if not selector.select(timeout=30):
                        raise RuntimeError("Bootstrap timed out")
                    bootstrap = json.loads(child.stdout.readline())
                base = "http://127.0.0.1:" + str(int(bootstrap["port"]))

                def request(path, body=None):
                    data = json.dumps(body).encode() if body is not None else None
                    req = urllib.request.Request(base + path, data=data, headers={
                        "Authorization": "Bearer " + token,
                        "Content-Type": "application/json",
                    })
                    with urllib.request.urlopen(req, timeout=10) as response:
                        return json.load(response)

                deadline = time.monotonic() + 60
                while time.monotonic() < deadline:
                    health = request("/health")
                    if health["status"] == "error":
                        break
                    if child.poll() is not None:
                        raise RuntimeError("Server exited unexpectedly")
                    time.sleep(.25)
                else:
                    raise RuntimeError("Expected missing-model error was not reported")
                request("/shutdown", {})
                if child.wait(timeout=20) != 0:
                    raise RuntimeError("Shutdown failed")
            finally:
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=5)
    if snapshot(app) != before:
        raise SystemExit("Application contents changed during runtime")
    if list((resources / "sidecar").rglob("*.pyc")):
        raise SystemExit("Python caches appeared inside the app")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print("PASS: startup/error/shutdown, unchanged bundle, no Python cache, valid signature")


if __name__ == "__main__":
    main()
