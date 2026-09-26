#!/bin/bash
# Claudebar hook: forwards a Claude Code or Codex hook payload (stdin) to the Claudebar app.
# Codex's hooks call it with CLAUDEBAR_AGENT=codex.
#
# Registered as an async hook, so it never delays the agent. If Claudebar isn't running,
# curl gets "connection refused" immediately; either way this exits 0.
#
# Headers carry what the payload doesn't:
#   X-Claudebar-Agent      claude or codex
#   X-Claudebar-Bundle     the app hosting the session (Claude desktop, iTerm, VS Code...)
#   X-Claudebar-Term       $TERM_PROGRAM, a fallback for picking the app to focus
#   X-Claudebar-Claude-PID / X-Claudebar-PPID
#                          used to notice sessions whose process died without SessionEnd

curl --silent --max-time 2 --output /dev/null \
  --header 'Content-Type: application/json' \
  --header 'Expect:' \
  --header "X-Claudebar-Agent: ${CLAUDEBAR_AGENT:-claude}" \
  --header "X-Claudebar-Bundle: ${__CFBundleIdentifier:-}" \
  --header "X-Claudebar-Term: ${TERM_PROGRAM:-}" \
  --header "X-Claudebar-Claude-PID: ${CLAUDE_PID:-}" \
  --header "X-Claudebar-PPID: ${PPID}" \
  --data-binary @- \
  "http://127.0.0.1:${CLAUDEBAR_PORT:-47823}/event" 2>/dev/null

exit 0
