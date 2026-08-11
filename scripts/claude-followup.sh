#!/bin/bash
# claude-followup.sh — inject a follow-up prompt into the SAME running Claude
# session Margie started (the "margie" tmux session), so it appears in the
# existing Warp tab. No new tab, no keystroke automation.
#
# Usage: claude-followup.sh <text...> [--branch <branch>]
#   --branch targets a worktree session started with kickoff --worktree <branch>;
#   omit it for the main session.
set -uo pipefail

TMUX_BIN="$(command -v tmux || echo /opt/homebrew/bin/tmux)"
SESSION="margie"

# Optional trailing "--branch <name>" selects a worktree session.
ARGS=("$@")
if [ "${#ARGS[@]}" -ge 2 ] && [ "${ARGS[${#ARGS[@]}-2]}" = "--branch" ]; then
  br="${ARGS[${#ARGS[@]}-1]}"
  SESSION="margie-$(printf '%s' "$br" | tr '/ ' '--')"
  unset 'ARGS[${#ARGS[@]}-1]' 'ARGS[${#ARGS[@]}-1]'
fi
TEXT="${ARGS[*]}"

if [ -z "$TEXT" ]; then
  echo "usage: claude-followup.sh <follow-up text> [--branch <branch>]" >&2
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
