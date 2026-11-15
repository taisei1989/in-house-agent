"""Opt-in real-model launchd verification; never runs during pytest collection.

Run only after coordinating exclusive model access:
  python -m sidecar.test_routine_integration --execute --model PATH

Creates an isolated routine definition/workspace and a uniquely named LaunchAgent.
Waits for StartCalendarInterval (not kickstart), observes real child processes,
checks the result, then unregisters only its own job. Notification verification
is deliberately excluded and reported as unverified.
"""
import argparse
from datetime import datetime, timedelta
import json
import hashlib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import uuid

import psutil


def launchctl(*args):
    return subprocess.run(["/bin/launchctl", *args], capture_output=True, text=True, timeout=20)


def active_model_processes():
    found = []
    for process in psutil.process_iter(["pid", "name", "cmdline"]):
        try:
            command = process.info["cmdline"] or []
            if process.pid == os.getpid():
                continue
            if any(value in command for value in ("sidecar.server", "sidecar.smoke")):
                found.append({"pid": process.pid, "name": process.info["name"]})
        except psutil.Error:
            pass
    return found


def app_is_running(allow_notification_for=None):
    for process in psutil.process_iter(["name", "cmdline"]):
        if process.info["name"] == "InHouseAgent":
            command = process.info["cmdline"] or []
            if allow_notification_for and "--routine-notify" in command:
                index = command.index("--routine-notify")
                if len(command) > index + 1 and command[index + 1] == allow_notification_for:
                    continue
            return True
    return False


def metadata(output):
    # Do not retain launchctl's environment or complete process arguments.
    data = {}
    for key in ("state", "pid", "runs", "last exit code"):
        match = re.search(r"^\s*" + re.escape(key) + r" = ([^\n]+)$", output, re.MULTILINE)
        if match:
            data[key] = match.group(1).strip()
    return data


def verify(args):
    if sys.platform != "darwin":
        raise SystemExit("This verification requires macOS launchd")
    model = Path(args.model).expanduser().resolve(strict=True)
    if active_model_processes():
        raise SystemExit("Another sidecar/model task is active. Coordinate exclusive model access first.")
    if app_is_running():
        raise SystemExit("Quit the app first; this test verifies scheduled execution while the app is closed.")
    if args.notify_executable and not (Path(args.notify_executable).is_file() and os.access(args.notify_executable, os.X_OK)):
        raise SystemExit("The requested notification executable does not exist or is not executable")
    identifier = str(uuid.uuid4()).upper()
    label = "com.taisei1989.inhouseagent.verification." + identifier
    target = f"gui/{os.getuid()}/{label}"
    root = Path(tempfile.mkdtemp(prefix="inhouse-routine-verification-"))
    workspace = root / "workspace"
    workspace.mkdir()
    for name in ("alpha.txt", "beta.md"):
        (workspace / name).write_text("launchd verification fixture\n")
    when = (datetime.now() + timedelta(minutes=2)).replace(second=0, microsecond=0)
    routine = {"id": identifier, "name": "LaunchAgent verification", "enabled": True,
               "schedule": when.strftime("%H:%M"), "workspace": str(workspace),
               "prompt": "Use list_directory to list all files in the current workspace. Return the exact file names."}
    definitions = root / "routines.json"
    definitions.write_text(json.dumps([routine]))
    logs = root / "logs"
    logs.mkdir()
    runner = Path(args.runner).expanduser().resolve(strict=True) if args.runner else Path(__file__).resolve().with_name("routine.py")
    original_routines = Path.home() / "Library/Application Support/InHouseAgent/routines.json"
    def routine_state():
        return hashlib.sha256(original_routines.read_bytes()).hexdigest() if original_routines.exists() else None
    original_routine_state = routine_state()
    agent_dir = Path.home() / "Library/LaunchAgents"
    agent_dir.mkdir(parents=True, exist_ok=True)
    plist = agent_dir / (label + ".plist")
    if plist.exists():
        raise SystemExit("Unique test LaunchAgent unexpectedly already exists")
    specification = {
        "Label": label,
        "ProgramArguments": [sys.executable, str(runner), "--routine", str(definitions),
                             "--id", identifier, "--model", str(model), "--notify-executable", args.notify_executable],
        "WorkingDirectory": str(workspace),
        "StartCalendarInterval": {"Hour": when.hour, "Minute": when.minute},
        "StandardOutPath": str(logs / "launchd.log"),
        "StandardErrorPath": str(logs / "launchd.log"),
        "ProcessType": "Background",
    }
    plist.write_bytes(plistlib.dumps(specification))
    plist.chmod(0o600)
    evidence = {"label": label, "scheduled_for": when.isoformat(),
                "notification_verified": False, "notification_note": "Pending delivery confirmation" if args.notify_executable else "Intentionally not tested",
                "evidence_directory": str(root), "observations": [],
                "runner_sha256": hashlib.sha256(runner.read_bytes()).hexdigest(),
                "python_version": sys.version.split()[0], "app_remained_closed": True}
    processes = {}
    registered = False
    try:
        boot = launchctl("bootstrap", f"gui/{os.getuid()}", str(plist))
        if boot.returncode:
            raise RuntimeError("launchctl bootstrap failed: " + boot.stderr.strip())
        registered = True
        evidence["registered"] = launchctl("print", target).returncode == 0
        print(json.dumps({"registered": evidence["registered"], "label": label,
                          "scheduled_for": when.isoformat(), "evidence_directory": str(root)}), flush=True)
        result_path = root / "routine-results" / (identifier + ".json")
        deadline = time.monotonic() + args.timeout
        last = None
        while time.monotonic() < deadline:
            if app_is_running(allow_notification_for=identifier if result_path.exists() else None):
                evidence["app_remained_closed"] = False
                raise RuntimeError("The app was opened during the app-closed routine verification")
            state = launchctl("print", target)
            current = metadata(state.stdout)
            if current != last:
                evidence["observations"].append({"at": datetime.now().isoformat(), **current})
                print(json.dumps(current), flush=True)
                last = current
            if current.get("pid", "").isdigit():
                try:
                    owner = psutil.Process(int(current["pid"]))
                    for child in [owner, *owner.children(recursive=True)]:
                        processes[(child.pid, child.create_time())] = child
                except psutil.Error:
                    pass
            if result_path.exists() and not current.get("pid"):
                result = json.loads(result_path.read_text())
                evidence["result"] = result
                if result.get("status") != "success":
                    raise RuntimeError("Real routine did not succeed; inspect isolated result/log files")
                if not all(name in result.get("message", "") for name in ("alpha.txt", "beta.md")):
                    raise RuntimeError("Real routine result did not include both known fixture files")
                if current.get("last exit code") != "0":
                    raise RuntimeError("LaunchAgent did not report exit code 0")
                evidence["real_model_files_verified"] = True
                if args.notify_executable:
                    if result.get("notification_status") != "delivered":
                        raise RuntimeError("Notification delivery was not confirmed by the installed app")
                    evidence["notification_verified"] = True
                    evidence["notification_note"] = "Installed helper confirmed UNUserNotificationCenter delivery"
                if not processes:
                    raise RuntimeError("No real LaunchAgent process was observed")
                break
            time.sleep(.5)
        else:
            raise TimeoutError("Scheduled real-model routine exceeded the verification timeout")
    except Exception as exc:
        evidence["error"] = str(exc)
        raise
    finally:
        if registered:
            out = launchctl("bootout", target)
            evidence["bootout_exit_code"] = out.returncode
        evidence["unregistered"] = launchctl("print", target).returncode != 0
        plist.unlink(missing_ok=True)
        evidence["plist_removed"] = not plist.exists()
        # Includes the independent guardian discovered while the task ran.
        deadline = time.monotonic() + 25
        alive = []
        while time.monotonic() < deadline:
            alive = []
            for (pid, born), process in processes.items():
                try:
                    if process.is_running() and process.create_time() == born and process.status() != psutil.STATUS_ZOMBIE:
                        alive.append({"pid": pid, "name": process.name()})
                except psutil.Error:
                    pass
            if not alive:
                break
            time.sleep(.5)
        evidence["observed_process_count"] = len(processes)
        evidence["remaining_owned_processes"] = alive
        evidence["existing_routine_definitions_unchanged"] = original_routine_state == routine_state()
        (root / "evidence.json").write_text(json.dumps(evidence, indent=2))
        print(json.dumps({"unregistered": evidence["unregistered"], "remaining_owned_processes": alive,
                          "evidence": str(root / "evidence.json"), "notification_verified": evidence["notification_verified"]}), flush=True)
    if not evidence["unregistered"] or evidence["remaining_owned_processes"] or not evidence["existing_routine_definitions_unchanged"]:
        raise RuntimeError("LaunchAgent or owned process cleanup is incomplete")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true", help="Explicit opt-in to registering a real LaunchAgent")
    parser.add_argument("--model", required=True)
    parser.add_argument("--runner", help="Optional bundled production sidecar/routine.py to verify")
    parser.add_argument("--notify-executable", default="", help="Installed app executable; requires delivery confirmation when supplied")
    parser.add_argument("--timeout", type=float, default=1200)
    args = parser.parse_args()
    if not args.execute:
        parser.error("--execute is required; this runs the real model via launchd")
    verify(args)
