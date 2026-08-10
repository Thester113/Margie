#!/bin/bash
# claude-followup.sh — inject a follow-up prompt into the SAME running Claude
# session Margie started (the "margie" tmux session), so it appears in the
# existing Warp tab. No new tab, no keystroke automation.
#
# Usage: claude-followup.sh <text of the follow-up...>
set -uo pipefail

TMUX_BIN="$(command -v tmux || echo /opt/homebrew/bin/tmux)"
SESSION="margie"
TEXT="$*"

if [ -z "$TEXT" ]; then
  echo "usage: claude-followup.sh <follow-up text>" >&2
  exit 1
fi

if ! "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null; then
  echo "No running Claude session to follow up on, sir — start one first with kickoff-claude.sh."
  exit 1
fi

# -l sends the text literally; then a separate Enter submits it to Claude.
"$TMUX_BIN" send-keys -t "$SESSION" -l -- "$TEXT"
"$TMUX_BIN" send-keys -t "$SESSION" Enter
echo "Follow-up sent into the running Claude session."
