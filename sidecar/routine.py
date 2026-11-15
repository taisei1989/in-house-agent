"""launchd entry point. Unattended mutations are denied, never auto-approved."""
import argparse
from contextlib import suppress
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import secrets
import selectors
import subprocess
import sys
import time
import urllib.error
import urllib.request
import psutil


def request(base, token, path, body=None, timeout=10):
    data = json.dumps(body).encode() if body is not None else None
    return urllib.request.urlopen(urllib.request.Request(base + path, data=data,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"}), timeout=timeout)


def execute(args):
    definitions_path = Path(args.routine).expanduser().resolve()
    support = definitions_path.parent
    output_dir = support / "routine-results"
    output_dir.mkdir(parents=True, exist_ok=True)
    definitions = json.loads(definitions_path.read_text())
    routine = next((item for item in definitions if item["id"].lower() == args.id.lower()), None)
    if routine is None:
        raise ValueError("Routine no longer exists")
    if not routine.get("enabled", False):
        return
    import uuid
    identifier = str(uuid.UUID(routine["id"]))
    result_path = output_dir / (routine["id"] + ".json")
    process = None
    owns_server = False
    base = None
    token = secrets.token_hex(32)
    log_dir = support / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    message, status = "", "error"
    with (support / "routine.lock").open("a") as lock, (log_dir / (identifier + ".log")).open("a") as log:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            log.write(f"\n{datetime.now(timezone.utc).isoformat()} Starting routine\n")
            log.flush()
            descriptor = support / "server.json"
            connection = json.loads(descriptor.read_text()) if descriptor.exists() else None
            if connection and not psutil.pid_exists(int(connection.get("pid", 0))):
                connection = None
            if connection:
                port = int(connection["port"])
                if not 1 <= port <= 65535:
                    raise ValueError("Invalid server port")
                # Read the secret straight into memory; never print or persist it.
                credentials = subprocess.run(["/usr/bin/security", "find-generic-password", "-s",
                    "com.taisei1989.inhouseagent.sidecar", "-a", "session", "-w"],
                    capture_output=True, text=True, timeout=15)
                if credentials.returncode != 0:
                    raise RuntimeError("Cannot access the running server credential in Keychain")
                token = credentials.stdout.strip()
                base = "http://127.0.0.1:" + str(port)
            else:
                owns_server = True
                process = subprocess.Popen([sys.executable, "-B", "-m", "sidecar.server", "--model", args.model,
                    "--workspace", routine["workspace"], "--parent-pid", str(os.getpid())],
                    cwd=str(Path(__file__).resolve().parent.parent), stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=log, text=True)
                process.stdin.write(json.dumps({"token": token}) + "\n")
                process.stdin.flush()
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    if not selector.select(timeout=30):
                        raise TimeoutError("Sidecar bootstrap timed out")
                    bootstrap = json.loads(process.stdout.readline())
                base = "http://127.0.0.1:" + str(bootstrap["port"])
            deadline = time.monotonic() + 600
            while time.monotonic() < deadline:
                if process and process.poll() is not None:
                    raise RuntimeError("Sidecar exited during model loading")
                try:
                    with request(base, token, "/health") as response:
                        health = json.load(response)
                    if health.get("backend") != "litert":
                        raise RuntimeError("Scheduled routines are local-only. Stop the cloud server or switch to LiteRT before running this routine.")
                    if health["status"] == "ready" and not health.get("busy", False):
                        break
                    if health["status"] == "error":
                        raise RuntimeError(health.get("error") or "Model failed to load")
                except urllib.error.HTTPError as exc:
                    raise RuntimeError(f"Running server authentication/request failed (HTTP {exc.code})") from None
                except urllib.error.URLError:
                    pass
                time.sleep(.5)
            else:
                raise TimeoutError("Model loading exceeded 10 minutes")
            text = []
            denied = False
            complete = False
            with request(base, token, "/chat", {"prompt": routine["prompt"], "workspace": routine["workspace"], "isolated": not owns_server, "local_only": True}, timeout=900) as stream:
                for line in stream:
                    if not line.startswith(b"data: "):
                        continue
                    event = json.loads(line[6:])
                    if event["type"] == "token":
                        text.append(event["text"])
                        log.write(event["text"])
                        log.flush()
                    elif event["type"] == "approval":
                        denied = True
                        with request(base, token, "/approvals/" + event["id"], {"approved": False}):
                            pass
                        log.write("\nDenied unattended tool: " + event["name"] + "\n")
                    elif event["type"] == "error":
                        raise RuntimeError(event["message"])
                    elif event["type"] == "done":
                        complete = True
            if not complete:
                raise RuntimeError("Response stream ended without completion")
            status = "needs_approval" if denied else "success"
            message = "".join(text)[-2000:] or "Routine completed"
            if denied:
                message = "Unattended changes were denied. Open the app to approve an interactive task.\n" + message
        except Exception as exc:
            message = str(exc)
            log.write("\nERROR: " + message + "\n")
        finally:
            if base and owns_server:
                with suppress(Exception):
                    with request(base, token, "/shutdown", {}):
                        pass
            if process:
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
            result = {"status": status, "message": message, "finished_at": datetime.now(timezone.utc).isoformat()}
            temporary = result_path.with_suffix(".tmp")
            temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2))
            temporary.replace(result_path)
        executable = args.notify_executable
        result["notification_status"] = "unavailable"
        if executable and Path(executable).is_file() and os.access(executable, os.X_OK):
            try:
                notification = subprocess.run([executable, "--routine-notify", routine["id"], "--routine-status", status,
                "--routine-message", "Routine finished. Open In-House Agent to view the result."], timeout=30, check=False, capture_output=True, text=True)
                delivered = notification.returncode == 0 and "Routine notification delivered" in notification.stdout.splitlines()
                result["notification_status"] = "delivered" if delivered else "error"
                result["notification_exit_code"] = notification.returncode
                if not delivered:
                    # Never relay stdout wholesale: only the fixed success marker
                    # is trusted as delivery evidence. Keep errors bounded/redacted.
                    detail = notification.stderr.strip().replace(token, "<redacted>")[:1000]
                    result["notification_error"] = detail or "Notification helper did not confirm delivery"
            except subprocess.TimeoutExpired:
                result["notification_status"] = "error"
                result["notification_error"] = "Notification delivery confirmation timed out"
            except OSError as exc:
                result["notification_status"] = "error"
                result["notification_error"] = str(exc).replace(token, "<redacted>")[:1000]
        with (log_dir / (identifier + ".log")).open("a") as log:
            log.write("\nNotification: " + result["notification_status"] + "\n")
            if result.get("notification_error"):
                log.write(result["notification_error"] + "\n")
        temporary = result_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2))
        temporary.replace(result_path)
    if status == "error":
        raise SystemExit(1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--routine", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--notify-executable", default="/Applications/In-House Agent.app/Contents/MacOS/InHouseAgent")
    execute(parser.parse_args())
