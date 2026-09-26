#!/bin/bash
# Registers Claudebar's forwarding hook for every Claude Code event it listens to, and for
# Codex's events in ~/.codex/hooks.json when Codex is installed.
# Idempotent: previous Claudebar entries are replaced, all other hooks are left alone.
# A backup of each file is written next to it first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONFIG_DIR/settings.json"
HOOK="$CONFIG_DIR/hooks/claudebar-hook.sh"
COMMAND="bash \"$HOOK\""
EVENTS='["SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure",
         "PermissionRequest","PermissionDenied","Notification","Elicitation","ElicitationResult",
         "SubagentStart","SubagentStop","PreCompact","PostCompact","MessageDisplay","Stop","StopFailure"]'

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_HOOKS="$CODEX_DIR/hooks.json"
CODEX_COMMAND="CLAUDEBAR_AGENT=codex bash \"$HOOK\""
CODEX_EVENTS='["SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PostToolUse","PermissionRequest",
               "SubagentStart","SubagentStop","PreCompact","PostCompact","Stop","Interrupt"]'

command -v jq >/dev/null || { echo "jq is required: brew install jq" >&2; exit 1; }

# Replaces this command's hook groups for each event, leaving everything else alone.
register() { # <file> <command> <events-json>
  local updated
  updated="$(jq --arg cmd "$2" --argjson events "$3" '
    def without_claudebar: map(select(any(.hooks[]?; .command == $cmd) | not));
    .hooks = ((.hooks // {}) | with_entries(.value |= without_claudebar))
    | reduce $events[] as $event (.;
        .hooks[$event] = ((.hooks[$event] // [])
          + [{hooks: [{type: "command", command: $cmd, async: true, timeout: 5}]}]))
  ' "$1")"
  # Write in place so the file keeps its permissions.
  printf '%s\n' "$updated" > "$1"
}

mkdir -p "$(dirname "$HOOK")"
install -m 755 "$ROOT/hooks/claudebar-hook.sh" "$HOOK"

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.claudebar-backup"

register "$SETTINGS" "$COMMAND" "$EVENTS"
echo "Claude Code hooks registered in $SETTINGS (backup: $SETTINGS.claudebar-backup)"

if [ -d "$CODEX_DIR" ]; then
  [ -f "$CODEX_HOOKS" ] || echo '{"hooks": {}}' > "$CODEX_HOOKS"
  cp "$CODEX_HOOKS" "$CODEX_HOOKS.claudebar-backup"
  register "$CODEX_HOOKS" "$CODEX_COMMAND" "$CODEX_EVENTS"
  echo "Codex hooks registered in $CODEX_HOOKS (backup: $CODEX_HOOKS.claudebar-backup)"
  echo "  Codex runs new hooks only after you trust them: open Codex, run /hooks, and trust them."
fi
