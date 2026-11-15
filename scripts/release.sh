#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${RELEASE_CONFIG:-$ROOT/release-config.json}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build}"
export RELEASE_CONFIG="$CONFIG" DERIVED_DATA
usage() {
  printf 'Usage: %s VERSION BUILD OWNER/REPO [--publish]\n       %s --generate-key\n' "$0" "$0"
}
find_tool() {
  local name="$1" candidate
  if [[ -n "${SPARKLE_BIN:-}" && -x "$SPARKLE_BIN/$name" ]]; then
    printf '%s\n' "$SPARKLE_BIN/$name"; return
  fi
  candidate="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin/$name"
  if [[ -x "$candidate" ]]; then printf '%s\n' "$candidate"; return; fi
  printf 'Missing Sparkle %s. Resolve packages first or set SPARKLE_BIN.\n' "$name" >&2
  return 1
}
if [[ "${1:-}" == '--generate-key' ]]; then
  "$(find_tool generate_keys)"
  printf 'Copy the PUBLIC key into release-config.json sparkle_public_key. Private key remains in Keychain.\n'
  exit 0
fi
if [[ $# -lt 3 || $# -gt 4 ]]; then usage; exit 2; fi
VERSION="$1"; BUILD_NUMBER="$2"; REPO="$3"; MODE="${4:-}"
if [[ -n "$MODE" && "$MODE" != '--publish' ]]; then usage; exit 2; fi
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
# Validate without mutating the checkout. Keep the proposed configuration in a
# private temporary directory until every publication preflight has passed.
python3 - "$CONFIG" "$VERSION" "$BUILD_NUMBER" "$REPO" "$TEMP_DIR/config.json" <<'PYCONFIG'
import base64, json, re, sys
from pathlib import Path
from urllib.parse import urlsplit
path, version, build, repo, output = sys.argv[1:]
if not re.fullmatch(r'\d+\.\d+\.\d+', version): raise SystemExit('VERSION must be major.minor.patch')
if not build.isdigit() or int(build) < 1: raise SystemExit('BUILD must be a positive integer')
if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo): raise SystemExit('OWNER/REPO is required')
c = json.loads(Path(path).read_text())
try:
    if len(base64.b64decode(c['sparkle_public_key'], validate=True)) != 32: raise ValueError()
except (ValueError, KeyError): raise SystemExit('Set the generated PUBLIC EdDSA key before releasing')
if c.get('github_repository') != repo: raise SystemExit('Repository argument must match the reviewed configuration')
if int(build) < int(c['build']) or tuple(map(int, version.split('.'))) < tuple(map(int, c['version'].split('.'))):
    raise SystemExit('Version and build cannot decrease')
if version != c['version'] and int(build) <= int(c['build']):
    raise SystemExit('Changing version requires a higher build number')
c.update(version=version, build=int(build))
if not c.get('feed_url'): c['feed_url'] = f'https://github.com/{repo}/releases/latest/download/appcast.xml'
url = urlsplit(c['feed_url'])
if url.scheme != 'https' or not url.hostname or url.username or url.password or url.fragment:
    raise SystemExit('Feed must use HTTPS without credentials or fragment')
Path(output).write_text(json.dumps(c, ensure_ascii=False, indent=2) + '\n')
PYCONFIG
if [[ "$MODE" == '--publish' ]]; then
  if [[ "$CONFIG" != "$ROOT/release-config.json" ]]; then
    printf 'Publishing requires the tracked root release-config.json.\n' >&2; exit 1
  fi
  git -C "$ROOT" ls-files --error-unmatch release-config.json >/dev/null
  if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    printf 'Publishing must start from a clean checkout. Commit reviewed source changes first.\n' >&2; exit 1
  fi
  START_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
  BRANCH="$(git -C "$ROOT" symbolic-ref --quiet --short HEAD)" || {
    printf 'Publishing requires a checked-out branch, not detached HEAD.\n' >&2; exit 1;
  }
  git -C "$ROOT" check-ref-format --branch "$BRANCH" >/dev/null
  FETCH_URL="$(git -C "$ROOT" remote get-url --all origin)"
  PUSH_URL="$(git -C "$ROOT" remote get-url --push --all origin)"
  python3 - "$REPO" "$FETCH_URL" "$PUSH_URL" <<'PYREMOTE'
import sys
repo, fetch, push = sys.argv[1:]
allowed = {f'https://github.com/{repo}', f'https://github.com/{repo}.git',
           f'git@github.com:{repo}', f'git@github.com:{repo}.git',
           f'ssh://git@github.com/{repo}', f'ssh://git@github.com/{repo}.git'}
if fetch not in allowed or push not in allowed:
    raise SystemExit('origin fetch and push URLs must each identify exactly the requested GitHub repository')
PYREMOTE
  gh api "repos/$REPO" > "$TEMP_DIR/repository.json"
  python3 - "$TEMP_DIR/repository.json" "$BRANCH" <<'PYREPO'
import json, sys
repo = json.load(open(sys.argv[1]))
if repo.get('visibility') != 'public': raise SystemExit('The unauthenticated update feed requires a public repository')
if repo.get('default_branch') != sys.argv[2]: raise SystemExit('Publish from the repository default branch')
PYREPO
  if git -C "$ROOT" show-ref --verify --quiet "refs/tags/v$VERSION"; then
    printf 'Local release tag already exists; it will not be replaced.\n' >&2; exit 1
  fi
  if [[ -n "$(git -C "$ROOT" ls-remote --tags origin "refs/tags/v$VERSION")" ]]; then
    printf 'Remote release tag already exists; it will not be replaced.\n' >&2; exit 1
  fi
fi
PUBLIC_KEY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sparkle_public_key"])' "$TEMP_DIR/config.json")"
KEYCHAIN_PUBLIC_KEY="$("$(find_tool generate_keys)" -p)"
if [[ "$PUBLIC_KEY" != "$KEYCHAIN_PUBLIC_KEY" ]]; then
  printf 'Configured public key does not match the existing Keychain signing key.\n' >&2; exit 1
fi
if [[ "$MODE" == '--publish' ]]; then
  gh release list --repo "$REPO" --limit 100 --json isDraft,isPrerelease,tagName > "$TEMP_DIR/releases.json"
  python3 - "$TEMP_DIR/releases.json" "$VERSION" "$TEMP_DIR/has-latest" <<'PYLATEST'
import json, pathlib, sys
releases = json.load(open(sys.argv[1]))
if any(r['tagName'] == 'v' + sys.argv[2] for r in releases):
    raise SystemExit('Release already exists')
pathlib.Path(sys.argv[3]).write_text('yes' if any(not r['isDraft'] and not r['isPrerelease'] for r in releases) else 'no')
PYLATEST
  if [[ "$(cat "$TEMP_DIR/has-latest")" == yes ]]; then
    LATEST_TAG="$(gh release view --repo "$REPO" --json tagName --jq .tagName)"
    gh release download "$LATEST_TAG" --repo "$REPO" --pattern appcast.xml --dir "$TEMP_DIR"
    "$(find_tool sign_update)" --verify "$TEMP_DIR/appcast.xml"
    python3 - "$TEMP_DIR/appcast.xml" "$VERSION" "$BUILD_NUMBER" <<'PYVERSION'
import sys, xml.etree.ElementTree as ET
path, version, build = sys.argv[1:]
ns = {'s': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items = ET.parse(path).findall('./channel/item')
if not items: raise SystemExit('Latest appcast has no releases; inspect it before publishing')
for item in items:
    old_build = item.findtext('s:version', namespaces=ns)
    old_version = item.findtext('s:shortVersionString', namespaces=ns)
    if old_build is None or old_version is None: raise SystemExit('Latest appcast lacks version metadata')
    if int(build) <= int(old_build) or tuple(map(int, version.split('.'))) <= tuple(map(int, old_version.split('.'))):
        raise SystemExit('New version AND build must exceed the published latest appcast')
PYVERSION
  fi
fi
cp "$TEMP_DIR/config.json" "$CONFIG"
"$ROOT/scripts/build.sh"
APP_NAME="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["app_name"])' "$CONFIG")"
APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
OUTPUT="$ROOT/dist/v$VERSION"
mkdir -p "$OUTPUT"
ARCHIVE="$OUTPUT/InHouseAgent-$VERSION.zip"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ "${SIGN_IDENTITY:--}" == '-' ]]; then
    printf 'Notarization requires SIGN_IDENTITY (Developer ID Application).\n' >&2; exit 1
  fi
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/notarization.zip"
  xcrun notarytool submit "$OUTPUT/notarization.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  codesign --verify --deep --strict "$APP"
fi
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
"$(find_tool sign_update)" "$ARCHIVE" > "$OUTPUT/signature.xml-fragment"
python3 - "$CONFIG" "$OUTPUT" "$ARCHIVE" <<'PY'
import datetime, email.utils, json, pathlib, sys, xml.etree.ElementTree as ET
config, output, archive = sys.argv[1:]
c = json.loads(pathlib.Path(config).read_text()); out = pathlib.Path(output)
ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', ns)
fragment = (out / 'signature.xml-fragment').read_text().strip()
attrs = ET.fromstring(f'<enclosure xmlns:sparkle="{ns}" {fragment} />').attrib
if f'{{{ns}}}edSignature' not in attrs or 'length' not in attrs: raise SystemExit('Invalid signature tool output')
if int(attrs['length']) != pathlib.Path(archive).stat().st_size: raise SystemExit('Archive size mismatch')
(out / 'archive-signature.txt').write_text(attrs[f'{{{ns}}}edSignature'])
rss = ET.Element('rss', version='2.0'); ch = ET.SubElement(rss, 'channel')
ET.SubElement(ch, 'title').text = c['app_name']
item = ET.SubElement(ch, 'item')
ET.SubElement(item, 'title').text = f"Version {c['version']}"
ET.SubElement(item, 'pubDate').text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
ET.SubElement(item, f'{{{ns}}}version').text = str(c['build'])
ET.SubElement(item, f'{{{ns}}}shortVersionString').text = c['version']
ET.SubElement(item, f'{{{ns}}}minimumSystemVersion').text = '14.0.0'
attrs.update(url=f"https://github.com/{c['github_repository']}/releases/download/v{c['version']}/{pathlib.Path(archive).name}", type='application/octet-stream')
ET.SubElement(item, 'enclosure', attrs)
ET.indent(rss)
ET.ElementTree(rss).write(out / 'appcast.xml', encoding='utf-8', xml_declaration=True)
PY
ARCHIVE_SIGNATURE="$(cat "$OUTPUT/archive-signature.txt")"
"$(find_tool sign_update)" --verify "$ARCHIVE" "$ARCHIVE_SIGNATURE"
"$(find_tool sign_update)" "$OUTPUT/appcast.xml"
"$(find_tool sign_update)" --verify "$OUTPUT/appcast.xml"
if [[ "$MODE" == '--publish' ]]; then
  # Only the metadata we prepared may differ. Do not stage or discard any
  # unrelated edits made while the potentially long build was running.
  if [[ "$(git -C "$ROOT" rev-parse HEAD)" != "$START_COMMIT" || "$(git -C "$ROOT" symbolic-ref --quiet --short HEAD)" != "$BRANCH" ]]; then
    printf 'Checkout changed during release preparation; leaving all work intact.\n' >&2; exit 1
  fi
  if ! cmp -s "$TEMP_DIR/config.json" "$CONFIG"; then
    printf 'Release configuration changed during the build; refusing to publish.\n' >&2; exit 1
  fi
  git -C "$ROOT" status --porcelain=v1 -z > "$TEMP_DIR/status"
  python3 - "$TEMP_DIR/status" <<'PYSTATUS'
import pathlib, sys
entries = [e for e in pathlib.Path(sys.argv[1]).read_bytes().split(b'\0') if e]
if any(e != b' M release-config.json' for e in entries):
    raise SystemExit('Files other than the prepared release metadata changed; leaving all changes intact')
PYSTATUS
  if ! git -C "$ROOT" diff --quiet -- release-config.json; then
    git -C "$ROOT" add -- release-config.json
    git -C "$ROOT" commit --only -m "Release $VERSION (build $BUILD_NUMBER)" -- release-config.json
  fi
  RELEASE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
  if [[ -n "$(git -C "$ROOT" status --porcelain)" ]] || ! cmp -s "$TEMP_DIR/config.json" "$CONFIG"; then
    printf 'Commit hooks changed release inputs; review and rebuild before publishing.\n' >&2; exit 1
  fi
  # A commit hook must not smuggle additional changes into the release commit.
  if [[ "$RELEASE_COMMIT" != "$START_COMMIT" ]]; then
    if [[ "$(git -C "$ROOT" diff --name-only "$START_COMMIT" "$RELEASE_COMMIT")" != 'release-config.json' ]]; then
      printf 'The release commit contains unexpected changes; refusing to publish.\n' >&2; exit 1
    fi
  fi
  git -C "$ROOT" tag "v$VERSION" "$RELEASE_COMMIT"
  # Atomic, non-force push: never publish the tag if a concurrent branch update
  # rejects the branch push, and never overwrite an existing tag.
  git -C "$ROOT" push --atomic origin "HEAD:refs/heads/$BRANCH" "refs/tags/v$VERSION:refs/tags/v$VERSION"
  REMOTE_TAG_COMMIT="$(gh api "repos/$REPO/commits/v$VERSION" --jq .sha)"
  if [[ "$RELEASE_COMMIT" != "$REMOTE_TAG_COMMIT" ]]; then
    printf 'Remote release tag differs from the signed build inputs; refusing to publish.\n' >&2; exit 1
  fi
  gh release create "v$VERSION" "$ARCHIVE" "$OUTPUT/appcast.xml" \
    --repo "$REPO" --title "$APP_NAME $VERSION" --generate-notes --latest --verify-tag
  gh release view "v$VERSION" --repo "$REPO" --json url,assets
else
  printf 'Prepared signed release in %s. Not published; add --publish to publish from a clean checkout.\n' "$OUTPUT"
fi
