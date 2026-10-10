#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-build.XXXXXX")"
trap 'rm -rf "$BUILD_WORKDIR"' EXIT
APP="$BUILD_WORKDIR/Heimdall.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ARCH="${HEIMDALL_ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64|x86_64) ARCHS=("$ARCH") ;;
  universal) ARCHS=(arm64 x86_64) ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
for TARGET_ARCH in "${ARCHS[@]}"; do
  xcrun swiftc -O -target "$TARGET_ARCH-apple-macosx13.0" -framework AppKit "$ROOT/Sources/Panel.swift" "$ROOT/Sources/main.swift" -o "$BUILD_WORKDIR/Heimdall-$TARGET_ARCH"
done
if [ "$ARCH" = universal ]; then
  xcrun lipo -create "$BUILD_WORKDIR/Heimdall-arm64" "$BUILD_WORKDIR/Heimdall-x86_64" -output "$APP/Contents/MacOS/Heimdall"
else
  cp "$BUILD_WORKDIR/Heimdall-$ARCH" "$APP/Contents/MacOS/Heimdall"
fi
xcrun swift "$ROOT/packaging/render-assets.swift" "$BUILD_WORKDIR/assets"
ICONSET="$BUILD_WORKDIR/Heimdall.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$BUILD_WORKDIR/assets/app-icon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE * 2))
  sips -z "$DOUBLE" "$DOUBLE" "$BUILD_WORKDIR/assets/app-icon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Heimdall.icns"
python3 - "$APP" <<'PY'
import pathlib,plistlib,sys
p=pathlib.Path(sys.argv[1])/'Contents/Info.plist'
p.write_bytes(plistlib.dumps({'CFBundleIdentifier':'io.github.theedward.heimdall','CFBundleName':'Heimdall','CFBundleDisplayName':'Heimdall','CFBundleExecutable':'Heimdall','CFBundleIconFile':'Heimdall.icns','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.1.0','CFBundleVersion':'3','LSMinimumSystemVersion':'13.0','LSUIElement':True,'NSHighResolutionCapable':True}))
PY
xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
mkdir -p "$ROOT/build"
ditto --norsrc "$APP" "$ROOT/build/Heimdall.app"
printf '%s\n' "$ROOT/build/Heimdall.app"
