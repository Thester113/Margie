#!/bin/bash
# session.sh — let Margie READ, STEER, and LIST the running Warp/tmux sessions
# she started, so she can watch a session and inject follow-ups based on the
# conversation with Tom.
#
# Usage:
#   session.sh read  [lines] [--branch <b>]   capture what the session is showing
#   session.sh send  "<text>" [--branch <b>]  inject a prompt + Enter (steer it)
#   session.sh list                           list the live margie sessions
#
# Default target is the most recently launched session (~/.margie/last-session),
# falling back to the newest live margie* session. --branch <b> targets a
# specific worktree session (margie-<branch>).
set -uo pipefail

TMUX_BIN="$(command -v tmux || echo /opt/homebrew/bin/tmux)"
cmd="${1:-read}"; shift || true

# Pull an optional "--branch <b>" from anywhere in the args.
BR=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --branch | -b) BR="${2:-}"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

resolve_session() {
  local S=""
  if [ -n "$BR" ]; then
    S="margie-$(printf '%s' "$BR" | tr '/ ' '--')"
  else
    S="$(cat "$HOME/.margie/last-session" 2>/dev/null || true)"
    if [ -z "$S" ] || ! "$TMUX_BIN" has-session -t "$S" 2>/dev/null; then
      S="$("$TMUX_BIN" list-sessions -F '#{session_created} #{session_name}' 2>/dev/null \
        | grep ' margie' | sort -nr | head -1 | awk '{print $2}')"
    fi
    [ -z "$S" ] && S="margie"
  fi
  echo "$S"
}

case "$cmd" in
  list)
    OUT="$("$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null | grep '^margie' || true)"
    [ -z "$OUT" ] && { echo "No running sessions, dearie."; exit 0; }
    echo "$OUT"
    ;;
  read | show | peek)
    SESSION="$(resolve_session)"
    LINES="${1:-200}"
    if ! "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null; then
      echo "No running session to read, dearie — start one first."
      exit 0
    fi
    echo "── session $SESSION ──"
    # Capture the visible pane plus recent scrollback, trim trailing blanks,
    # drop empty lines, and cap the size for the brain to read.
    "$TMUX_BIN" capture-pane -t "$SESSION" -p -S "-$LINES" 2>/dev/null \
      | sed 's/[[:space:]]*$//' | grep -v '^$' | tail -c 6000
    ;;
  send | inject | steer)
    SESSION="$(resolve_session)"
    TEXT="$*"
    [ -z "$TEXT" ] && { echo "usage: session.sh send \"<text>\" [--branch <b>]" >&2; exit 1; }
    if ! "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null; then
      echo "No running session to steer, dearie — start one first with kickoff-claude.sh."
      exit 1
    fi
    "$TMUX_BIN" send-keys -t "$SESSION" -l -- "$TEXT"
    "$TMUX_BIN" send-keys -t "$SESSION" Enter
    echo "Sent into session $SESSION, dearie."
    ;;
  *)
    echo "usage: session.sh read [lines] | send \"<text>\" | list [--branch <b>]" >&2
    exit 1
    ;;
esac
