#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Disk Beacon.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -target "$(uname -m)-apple-macosx13.0" -framework AppKit "$ROOT/Sources/DiskBeacon.swift" -o "$APP/Contents/MacOS/DiskBeacon"
python3 - "$APP" <<'PY'
import pathlib,plistlib,sys
p=pathlib.Path(sys.argv[1])/'Contents/Info.plist'
p.write_bytes(plistlib.dumps({'CFBundleIdentifier':'io.github.theedward.disk-beacon','CFBundleName':'Disk Beacon','CFBundleDisplayName':'Disk Beacon','CFBundleExecutable':'DiskBeacon','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0.0','CFBundleVersion':'1','LSMinimumSystemVersion':'13.0','LSUIElement':True,'NSHighResolutionCapable':True}))
PY
xattr -cr "$APP"
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
