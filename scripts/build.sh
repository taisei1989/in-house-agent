#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${RELEASE_CONFIG:-$ROOT/release-config.json}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build}"
# Treat the configuration as data, never as shell or PlistBuddy commands.
python3 - "$CONFIG" <<'PY'
import base64, json, re, sys
from urllib.parse import urlsplit
c = json.load(open(sys.argv[1]))
name = c.get('app_name', '')
if not isinstance(name, str) or not name or name in {'.', '..'} or any(ch in name for ch in '/\\\r\n\0'):
    raise SystemExit('app_name must be a single safe filename')
if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', c.get('bundle_id', '')):
    raise SystemExit('Invalid bundle_id')
if not re.fullmatch(r'\d+\.\d+\.\d+', c.get('version', '')) or type(c.get('build')) is not int or c['build'] < 1:
    raise SystemExit('Invalid release version/build')
url = urlsplit(c.get('feed_url', ''))
if url.scheme != 'https' or not url.hostname or url.username or url.password or url.fragment:
    raise SystemExit('feed_url must be an HTTPS URL without credentials or fragment')
try:
    if len(base64.b64decode(c['sparkle_public_key'], validate=True)) != 32: raise ValueError()
except (ValueError, KeyError):
    raise SystemExit('Invalid Sparkle public key')
PY
read_config() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$CONFIG" "$1"; }
APP_NAME="$(read_config app_name)"
BUNDLE_ID="$(read_config bundle_id)"
VERSION="$(read_config version)"
BUILD_NUMBER="$(read_config build)"
FEED_URL="$(read_config feed_url)"
PUBLIC_KEY="$(read_config sparkle_public_key)"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
RUNTIME=NO
if [[ "$SIGN_IDENTITY" != '-' ]]; then RUNTIME=YES; fi
# Do not ship developer checkout paths in Swift source-location metadata.
SWIFT_PATH_MAP="-file-prefix-map \"$ROOT\"=. -debug-prefix-map \"$ROOT\"=."
xcodebuild -project "$ROOT/InHouseAgent.xcodeproj" -scheme InHouseAgent \
  -configuration Release -derivedDataPath "$DERIVED_DATA" \
  PRODUCT_NAME="$APP_NAME" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGN_STYLE=Manual \
  ENABLE_HARDENED_RUNTIME="$RUNTIME" OTHER_SWIFT_FLAGS="$SWIFT_PATH_MAP" build
APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
PLIST="$APP/Contents/Info.plist"
# Rebuild the bundled Python sources from an explicit allowlist. Folder
# resources otherwise copy local caches, tests and accidental secret files.
python3 - "$ROOT" "$APP" <<'PY'
import pathlib, shutil, sys
root, app = map(pathlib.Path, sys.argv[1:])
destination = app / 'Contents/Resources/sidecar'
if destination.is_symlink(): raise SystemExit('Refusing symlinked sidecar resource')
if destination.exists(): shutil.rmtree(destination)
destination.mkdir(parents=True)
for name in ['__init__.py', 'backend.py', 'cloud_proxy.py', 'guardian.py', 'routine.py', 'server.py']:
    source = root / 'sidecar' / name
    if source.is_symlink() or not source.is_file(): raise SystemExit(f'Invalid bundled source: {name}')
    shutil.copyfile(source, destination / name)
PY
python3 - "$CONFIG" "$PLIST" <<'PY'
import json, pathlib, plistlib, sys
c = json.load(open(sys.argv[1])); path = pathlib.Path(sys.argv[2])
p = plistlib.loads(path.read_bytes())
p.update(CFBundleShortVersionString=c['version'], CFBundleVersion=str(c['build']),
         SUFeedURL=c['feed_url'], SUPublicEDKey=c['sparkle_public_key'],
         SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True)
path.write_bytes(plistlib.dumps(p, fmt=plistlib.FMT_BINARY))
PY
if [[ "$SIGN_IDENTITY" == '-' ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
python3 - "$APP" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
if str(pathlib.Path.home()).encode() in executable.read_bytes():
    raise SystemExit('Release executable contains a developer home path; fix prefix mapping before distribution')
if list((app / 'Contents/Resources/sidecar').rglob('*.pyc')):
    raise SystemExit('Compiled Python caches must not be distributed')
print('Release privacy checks passed')
PY
printf 'Built and verified: %s\n' "$APP"
