#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-package.XXXXXX")"
cleanup() {
  if [ -d "$PACKAGE_WORKDIR/mount" ]; then hdiutil detach "$PACKAGE_WORKDIR/mount" >/dev/null 2>&1 || true; fi
  rm -rf "$PACKAGE_WORKDIR"
}
trap cleanup EXIT
export HEIMDALL_ARCH="${HEIMDALL_ARCH:-universal}"
"$ROOT/build.sh"
ditto --norsrc "$ROOT/build/Heimdall.app" "$PACKAGE_WORKDIR/Heimdall.app"
xattr -cr "$PACKAGE_WORKDIR/Heimdall.app"
codesign --force --sign - "$PACKAGE_WORKDIR/Heimdall.app"
codesign --verify --strict "$PACKAGE_WORKDIR/Heimdall.app"
xcrun swift "$ROOT/packaging/render-assets.swift" "$PACKAGE_WORKDIR/assets"
python3 -m venv "$PACKAGE_WORKDIR/venv"
"$PACKAGE_WORKDIR/venv/bin/python" -m pip install --quiet -r "$ROOT/packaging/requirements.txt"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PACKAGE_WORKDIR/Heimdall.app/Contents/Info.plist")
NAME="Heimdall-${VERSION}-${HEIMDALL_ARCH}.dmg"
"$PACKAGE_WORKDIR/venv/bin/dmgbuild" -s "$ROOT/packaging/dmg-settings.py" -D "app=$PACKAGE_WORKDIR/Heimdall.app" -D "background=$PACKAGE_WORKDIR/assets/installer-background.png" Heimdall "$PACKAGE_WORKDIR/$NAME"
hdiutil verify "$PACKAGE_WORKDIR/$NAME"
mkdir "$PACKAGE_WORKDIR/mount"
hdiutil attach -readonly -nobrowse -mountpoint "$PACKAGE_WORKDIR/mount" "$PACKAGE_WORKDIR/$NAME" >/dev/null
"$PACKAGE_WORKDIR/venv/bin/python" - "$PACKAGE_WORKDIR/mount" "$HEIMDALL_ARCH" <<'PYVERIFY'
import os,pathlib,plistlib,subprocess,sys
from ds_store import DSStore
mount=pathlib.Path(sys.argv[1]); app=mount/'Heimdall.app'
assert app.is_dir()
assert os.readlink(mount/'Applications') == '/Applications'
with DSStore.open(str(mount/'.DS_Store'),'r') as store:
    assert store['Heimdall.app']['Iloc'] == (146,184)
    assert store['Applications']['Iloc'] == (420,184)
    assert store['.']['icvp']['backgroundType'] == 2
subprocess.run(['codesign','--verify','--strict',str(app)],check=True)
binary=app/'Contents/MacOS/Heimdall'
arch=set(subprocess.check_output(['lipo','-archs',str(binary)],text=True).split())
expected={'arm64','x86_64'} if sys.argv[2]=='universal' else {sys.argv[2]}
assert arch == expected
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleIconFile']=='Heimdall.icns'
assert (app/'Contents/Resources/Heimdall.icns').stat().st_size>0
print('Verified mounted installer: app signature, architectures, icon, background, positions and Applications shortcut.')
PYVERIFY
hdiutil detach "$PACKAGE_WORKDIR/mount" >/dev/null
rmdir "$PACKAGE_WORKDIR/mount"
mkdir -p "$ROOT/build" "$ROOT/docs/previews"
cp "$PACKAGE_WORKDIR/$NAME" "$ROOT/build/$NAME"
cp "$PACKAGE_WORKDIR/assets/installer-preview.png" "$ROOT/docs/previews/installer.png"
(cd "$ROOT/build" && shasum -a 256 "$NAME" > "$NAME.sha256")
printf '%s\n' "$ROOT/build/$NAME"
