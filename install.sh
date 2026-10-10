#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
"$ROOT/build.sh"
DEST="$HOME/Applications/Disk Beacon.app"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
if pgrep -x DiskBeacon >/dev/null; then
  echo 'Quit Disk Beacon from its menu before installing an update.' >&2
  exit 1
fi
ditto --norsrc "$ROOT/build/Disk Beacon.app" "$DEST"
xattr -cr "$DEST"
codesign --force --sign - "$DEST"
codesign --verify --strict "$DEST"
python3 - "$DEST" "$HOME/Library/LaunchAgents/io.github.theedward.disk-beacon.plist" <<'PY'
import pathlib,plistlib,sys
pathlib.Path(sys.argv[2]).write_bytes(plistlib.dumps({'Label':'io.github.theedward.disk-beacon','ProgramArguments':['/usr/bin/open','-g',sys.argv[1]],'RunAtLoad':True}))
PY
open -g "$DEST"
printf 'Installed %s with launch at login enabled.\n' "$DEST"
