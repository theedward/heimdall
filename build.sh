#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-build.XXXXXX")"
trap 'rm -rf "$BUILD_WORKDIR"' EXIT
APP="$BUILD_WORKDIR/Heimdall.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -target "$(uname -m)-apple-macosx13.0" -framework AppKit "$ROOT/Sources/Panel.swift" "$ROOT/Sources/main.swift" -o "$APP/Contents/MacOS/Heimdall"
python3 - "$APP" <<'PY'
import pathlib,plistlib,sys
p=pathlib.Path(sys.argv[1])/'Contents/Info.plist'
p.write_bytes(plistlib.dumps({'CFBundleIdentifier':'io.github.theedward.heimdall','CFBundleName':'Heimdall','CFBundleDisplayName':'Heimdall','CFBundleExecutable':'Heimdall','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.1.0','CFBundleVersion':'2','LSMinimumSystemVersion':'13.0','LSUIElement':True,'NSHighResolutionCapable':True}))
PY
xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
mkdir -p "$ROOT/build"
ditto --norsrc "$APP" "$ROOT/build/Heimdall.app"
printf '%s\n' "$ROOT/build/Heimdall.app"
