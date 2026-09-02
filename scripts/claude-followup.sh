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
SESSION=""

# Optional trailing "--branch <name>" selects a specific worktree session.
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

# Default target: the most recently launched session. Fall back to the newest
# live margie* tmux session if the recorded one is gone.
if [ -z "$SESSION" ]; then
  SESSION="$(cat "$HOME/.margie/last-session" 2>/dev/null || true)"
  if [ -z "$SESSION" ] || ! "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null; then
    SESSION="$("$TMUX_BIN" list-sessions -F '#{session_created} #{session_name}' 2>/dev/null \
      | grep ' margie' | sort -nr | head -1 | awk '{print $2}')"
  fi
  [ -z "$SESSION" ] && SESSION="margie"
fi

if ! "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null; then
  echo "No running Claude session to follow up on, dearie — start one first with kickoff-claude.sh."
  exit 1
fi

# -l sends the text literally; then a separate Enter submits it to Claude.
"$TMUX_BIN" send-keys -t "$SESSION" -l -- "$TEXT"
"$TMUX_BIN" send-keys -t "$SESSION" Enter
echo "Follow-up sent into the running Claude session."
