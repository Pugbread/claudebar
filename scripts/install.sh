#!/bin/bash
# Builds Claudebar, installs it to ~/Applications, registers the hooks, and launches it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications/Claudebar.app"

"$ROOT/scripts/build.sh"

pkill -x Claudebar 2>/dev/null && sleep 0.5 || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$ROOT/build/Claudebar.app" "$DEST"

"$ROOT/scripts/install-hooks.sh"

open "$DEST"
echo "Claudebar is running. New Claude Code sessions will show up in the notch."
