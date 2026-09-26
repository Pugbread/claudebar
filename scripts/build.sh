#!/bin/bash
# Builds build/Claudebar.app (release, ad-hoc signed).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Claudebar.app"

cd "$ROOT"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Claudebar"

if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
  "$ROOT/scripts/make-icon.sh" || echo "warning: icon generation failed, continuing without one"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Claudebar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
