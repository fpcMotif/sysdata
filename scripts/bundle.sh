#!/bin/sh
# Wraps the release binary in dist/SysData GPUI.app (menu bar only, no Dock icon).
# Not under target/: the build cache may keep target/ inside ~/Library/Caches,
# which this app lists as a cache you can delete.
set -eu
cd "$(dirname "$0")/.."
binary=target/release/sysdata
test -x "$binary" || { echo "Build missing: $binary" >&2; exit 1; }
bundle="dist/SysData GPUI.app"
mkdir -p "$bundle/Contents/MacOS"
install -m 755 "$binary" "$bundle/Contents/MacOS/sysdata"
install -m 644 packaging/Info.plist "$bundle/Contents/Info.plist"
# Ad-hoc signature, so macOS keeps one Full Disk Access grant for this path.
codesign --force --sign - "$bundle" >/dev/null 2>&1
echo "$PWD/$bundle"
