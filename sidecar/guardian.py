"""Independent reaper for SDK descendants when the sidecar is SIGKILLed."""
import os
import signal
import sys
import time
import psutil


def reap(owner_pid):
    try:
        owner = psutil.Process(owner_pid)
        born = owner.create_time()
    except psutil.Error:
        return
    children = {}
    isolated_group = os.getpgid(owner_pid) == owner_pid
    while True:
        try:
            if not owner.is_running() or owner.create_time() != born or owner.status() == psutil.STATUS_ZOMBIE:
                break
            for child in owner.children(recursive=True):
                if child.pid != os.getpid():
                    children[child.pid] = child
        except psutil.NoSuchProcess:
            break
        except (psutil.AccessDenied, PermissionError):
            pass
        time.sleep(.2)
    if isolated_group:
        # The sidecar owns this session; its SDK children inherit the group.
        # The guardian has its own session and cannot kill itself here.
        try:
            os.killpg(owner_pid, signal.SIGTERM)
            time.sleep(3)
            # Do not signal a newly reused process-group leader PID.
            reused = False
            try:
                reused = psutil.Process(owner_pid).create_time() != born
            except psutil.NoSuchProcess:
                pass
            if not reused:
                os.killpg(owner_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    live = []
    for child in children.values():
        try:
            if child.is_running():
                child.terminate()
                live.append(child)
        except psutil.Error:
            pass
    _, alive = psutil.wait_procs(live, timeout=3)
    for child in alive:
        try:
            child.kill()
        except psutil.Error:
            pass


if __name__ == "__main__":
    reap(int(sys.argv[1]))
