#!/bin/bash
# Removes Claudebar's hooks from settings.json, the hook script, and the app.
set -euo pipefail

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONFIG_DIR/settings.json"
HOOK="$CONFIG_DIR/hooks/claudebar-hook.sh"
COMMAND="bash \"$HOOK\""

if [ -f "$SETTINGS" ] && command -v jq >/dev/null; then
  cp "$SETTINGS" "$SETTINGS.claudebar-backup"
  UPDATED="$(jq --arg cmd "$COMMAND" '
    if .hooks then
      .hooks |= (with_entries(.value |= map(select(any(.hooks[]?; .command == $cmd) | not)))
                 | with_entries(select(.value | length > 0)))
    else . end
  ' "$SETTINGS")"
  printf '%s\n' "$UPDATED" > "$SETTINGS"
  echo "Removed Claudebar hooks from $SETTINGS"
fi

CODEX_HOOKS="${CODEX_HOME:-$HOME/.codex}/hooks.json"
CODEX_COMMAND="CLAUDEBAR_AGENT=codex bash \"$HOOK\""
if [ -f "$CODEX_HOOKS" ] && command -v jq >/dev/null; then
  cp "$CODEX_HOOKS" "$CODEX_HOOKS.claudebar-backup"
  UPDATED="$(jq --arg cmd "$CODEX_COMMAND" '
    if .hooks then
      .hooks |= (with_entries(.value |= map(select(any(.hooks[]?; .command == $cmd) | not)))
                 | with_entries(select(.value | length > 0)))
    else . end
  ' "$CODEX_HOOKS")"
  printf '%s\n' "$UPDATED" > "$CODEX_HOOKS"
  echo "Removed Claudebar hooks from $CODEX_HOOKS"
fi

rm -f "$HOOK"
pkill -x Claudebar 2>/dev/null || true
rm -rf "$HOME/Applications/Claudebar.app"
echo "Claudebar uninstalled."
