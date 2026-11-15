#!/usr/bin/env python3
"""Offline release-workflow tests. Build, signing, GitHub and archive I/O are mocks.

Git commits/tags use disposable repositories; every push goes to a local bare
repository. These tests do NOT verify real Sparkle signatures or real releases.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


REAL_GIT = shutil.which("git")
PUBLIC_KEY = base64.b64encode(bytes(32)).decode()


def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


def git(root, *args):
    return subprocess.check_output([REAL_GIT, "-C", str(root), *args], text=True, stderr=subprocess.PIPE).strip()


def fixture(base, script):
    root, origin, mocks = base / "checkout", base / "origin.git", base / "mocks"
    root.mkdir(); mocks.mkdir(); (root / "scripts").mkdir()
    subprocess.run([REAL_GIT, "init", "--bare", str(origin)], check=True, capture_output=True)
    git(root, "init", "-b", "main")
    git(root, "config", "user.name", "Release Test")
    git(root, "config", "user.email", "release-test@example.invalid")
    (root / ".gitignore").write_text("build/\ndist/\n")
    (root / "source.txt").write_text("reviewed source\n")
    (root / "release-config.json").write_text(json.dumps({
        "app_name": "In-House Agent", "bundle_id": "com.example.inhouseagent",
        "version": "0.1.0", "build": 1, "github_repository": "owner/repo",
        "feed_url": "https://github.com/owner/repo/releases/latest/download/appcast.xml",
        "sparkle_public_key": PUBLIC_KEY,
    }, indent=2) + "\n")
    executable(root / "scripts/release.sh", script)
    executable(root / "scripts/build.sh", """#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(__file__).resolve().parents[1]
if os.environ.get('FAIL_BUILD'): sys.exit(23)
app = root / 'build/Build/Products/Release/In-House Agent.app'
app.mkdir(parents=True, exist_ok=True)
(app / 'binary').write_text('mock build')
if os.environ.get('DIRTY_BUILD'): (root / 'source.txt').write_text('unrelated concurrent edit')
if os.environ.get('ALTER_CONFIG'):
    p = root / 'release-config.json'; c = json.loads(p.read_text()); c['build'] += 1; p.write_text(json.dumps(c))
""")
    git(root, "add", "."); git(root, "commit", "-m", "Reviewed source")
    git(root, "remote", "add", "origin", str(origin))
    git(root, "push", "origin", "main")
    executable(mocks / "git", """#!/usr/bin/env python3
import os, subprocess, sys
a = sys.argv[1:]
if 'remote' in a and 'get-url' in a:
    print(os.environ.get('MOCK_REMOTE', 'https://github.com/owner/repo.git')); sys.exit(0)
if 'push' in a and os.environ.get('FAIL_PUSH'): sys.exit(24)
sys.exit(subprocess.call([os.environ['REAL_GIT'], *a]))
""")
    executable(mocks / "gh", """#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
a = sys.argv[1:]
if a[:1] == ['api']:
    if '/commits/' in a[1]:
        tag = a[1].split('/commits/')[1]
        print(subprocess.check_output([os.environ['REAL_GIT'], '--git-dir', os.environ['MOCK_ORIGIN'], 'rev-parse', tag], text=True).strip())
    else: print(json.dumps({'visibility': os.environ.get('MOCK_VISIBILITY', 'public'), 'default_branch': 'main'}))
elif a[:2] == ['release', 'list']:
    tag = os.environ.get('MOCK_RELEASE_TAG')
    print(json.dumps([{'isDraft': False, 'isPrerelease': False, 'tagName': tag}] if tag else []))
elif a[:2] == ['release', 'download']:
    p = pathlib.Path(a[a.index('--dir') + 1]) / 'appcast.xml'
    p.write_text('<rss xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><s:version>10</s:version><s:shortVersionString>1.0.0</s:shortVersionString></item></channel></rss>')
elif a[:2] == ['release', 'view']:
    print(os.environ.get('MOCK_RELEASE_TAG', '{}'))
elif a[:2] == ['release', 'create']:
    if os.environ.get('FAIL_PUBLISH'): sys.exit(25)
    pathlib.Path(os.environ['MOCK_PUBLISHED']).write_text(json.dumps(a))
else: raise SystemExit('Unexpected gh mock command')
""")
    executable(mocks / "generate_keys", """#!/usr/bin/env python3
import os
print(os.environ['MOCK_KEY'])
""")
    executable(mocks / "sign_update", """#!/usr/bin/env python3
import os, pathlib, sys
if os.environ.get('FAIL_SIGN'): sys.exit(26)
a = sys.argv[1:]
if a[0] == '--verify': sys.exit(0)
p = pathlib.Path(a[0])
if p.suffix != '.xml': print('sparkle:edSignature="MOCK-SIGNATURE" length="%s"' % p.stat().st_size)
""")
    executable(mocks / "ditto", """#!/usr/bin/env python3
import pathlib, sys
pathlib.Path(sys.argv[-1]).write_bytes(b'MOCK-ARCHIVE')
""")
    env = os.environ.copy()
    for key in ["RELEASE_CONFIG", "DERIVED_DATA", "NOTARY_PROFILE", "SIGN_IDENTITY"]:
        env.pop(key, None)
    env.update(PATH=str(mocks) + os.pathsep + env["PATH"], REAL_GIT=REAL_GIT,
               SPARKLE_BIN=str(mocks), MOCK_KEY=PUBLIC_KEY, MOCK_ORIGIN=str(origin),
               MOCK_PUBLISHED=str(base / "published.json"))
    return root, origin, env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--script", type=Path, default=Path(__file__).with_name("release.sh"))
    args = parser.parse_args()
    script = args.script.read_text()
    cases = ["success", "prepare", "dirty", "branch", "detached", "remote", "private",
             "local_tag", "remote_tag", "existing_release", "older_release", "key",
             "build", "signature", "concurrent_edit", "changed_config", "push", "publish"]
    for case in cases:
        with tempfile.TemporaryDirectory(prefix="inhouse-release-test-") as directory:
            base = Path(directory); root, origin, env = fixture(base, script)
            initial = git(root, "rev-parse", "HEAD")
            before_config = (root / "release-config.json").read_bytes()
            if case == "dirty": (root / "source.txt").write_text("user edit")
            if case == "branch": git(root, "switch", "-c", "feature")
            if case == "detached": git(root, "checkout", "--detach")
            if case == "remote": env["MOCK_REMOTE"] = "https://github.com/other/repo.git"
            if case == "private": env["MOCK_VISIBILITY"] = "private"
            if case in {"local_tag", "remote_tag"}:
                git(root, "tag", "v0.1.1")
                if case == "remote_tag":
                    git(root, "push", "origin", "v0.1.1"); git(root, "tag", "-d", "v0.1.1")
            if case == "existing_release": env["MOCK_RELEASE_TAG"] = "v0.1.1"
            if case == "older_release": env["MOCK_RELEASE_TAG"] = "v1.0.0"
            if case == "key": env["MOCK_KEY"] = base64.b64encode(bytes([1]) * 32).decode()
            for name, variable in [("build", "FAIL_BUILD"), ("signature", "FAIL_SIGN"),
                                   ("concurrent_edit", "DIRTY_BUILD"), ("changed_config", "ALTER_CONFIG"),
                                   ("push", "FAIL_PUSH"), ("publish", "FAIL_PUBLISH")]:
                if case == name: env[variable] = "1"
            command = ["bash", str(root / "scripts/release.sh"), "0.1.1", "2", "owner/repo"]
            if case != "prepare": command.append("--publish")
            result = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True, timeout=30)
            expected = case in {"success", "prepare"}
            assert (result.returncode == 0) == expected, (case, result.stdout, result.stderr)
            assert (base / "published.json").exists() == (case == "success"), case
            if case == "success":
                assert git(root, "rev-parse", "HEAD") != initial
                assert git(root, "diff", "--name-only", initial, "HEAD") == "release-config.json"
                assert git(root, "status", "--porcelain") == ""
                remote = subprocess.check_output([REAL_GIT, "--git-dir", str(origin), "rev-parse", "v0.1.1"], text=True).strip()
                assert remote == git(root, "rev-parse", "HEAD")
            elif case in {"push", "publish"}:
                assert git(root, "rev-parse", "HEAD") != initial, "Failure must preserve the release commit"
                assert git(root, "rev-parse", "v0.1.1") == git(root, "rev-parse", "HEAD")
            else:
                assert git(root, "rev-parse", "HEAD") == initial, case
                if case not in {"prepare", "build", "signature", "concurrent_edit", "changed_config"}:
                    assert (root / "release-config.json").read_bytes() == before_config, case
            if case == "concurrent_edit": assert (root / "source.txt").read_text() == "unrelated concurrent edit"
            print(f"PASS {case}")
    print(f"{len(cases)} offline workflow cases passed; no real builds, signatures or GitHub publication performed.")


if __name__ == "__main__":
    main()
