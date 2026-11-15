"""Host-side PID-only companion for XCTest runners that hide descendant PIDs.

Run alongside a single normal-quit or update UI test, without another server task.
It reads the connection descriptor's PID only and never accesses credentials.
"""
import json
import os
from pathlib import Path
import subprocess
import time


def main() -> int:
    descriptor = Path.home() / "Library/Application Support/InHouseAgent/server.json"
    observed: set[int] = set()
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        try:
            root = json.loads(descriptor.read_text())["pid"]
            if not isinstance(root, int) or root <= 1:
                raise ValueError("Invalid sidecar PID")
            pairs = [tuple(map(int, row.split())) for row in subprocess.check_output(
                ["/bin/ps", "-axo", "pid=,ppid="], text=True).splitlines()]
            owned = {root}
            for _ in range(16):
                before = len(owned)
                owned.update(pid for pid, parent in pairs if parent in owned)
                if len(owned) == before:
                    break
            observed.update(owned)
        except FileNotFoundError:
            if observed:
                break
        time.sleep(0.5)
    time.sleep(2)
    remaining = 0
    for pid in observed:
        try:
            os.kill(pid, 0)
            remaining += 1
        except ProcessLookupError:
            pass
    print(json.dumps({"observed_count": len(observed), "remaining_count": remaining}))
    return 0 if len(observed) >= 2 and remaining == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
