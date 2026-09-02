#!/bin/bash
# session.sh — let Margie READ, STEER, and LIST the running Warp/tmux sessions
# she started, so she can watch a session and inject follow-ups based on the
# conversation with Tom.
#
# Usage:
#   session.sh read  [lines] [--branch <b>]   capture what the session is showing
#   session.sh send  "<text>" [--branch <b>]  inject a prompt + Enter (steer it)
#   session.sh list                           list the live margie sessions
#   session.sh needs                          one line per session waiting on a human
#                                             (permission menu, trust check, y/n, or a
#                                             question idle > 3 min); silent otherwise —
#                                             the daemon polls this and Margie tells Tom
#   session.sh key <key…> [--branch <b>]      press keys: Enter, Escape, y, 1, Down …
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
  needs)
    ST="$HOME/.margie/session-needs"; mkdir -p "$ST"; NOW="$(date +%s)"
    LIVE="$("$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null | grep '^margie' || true)"
    # Sessions seen before that are gone now: announce the end once, with their last lines.
    for f in "$ST"/*.hash; do
      [ -f "$f" ] || continue; S="$(basename "$f" .hash)"
      printf '%s\n' "$LIVE" | grep -qxF "$S" && continue
      echo "Session $S has ended. Last seen: $(cat "$ST/$S.tail" 2>/dev/null | cut -c1-220)"
      rm -f "$ST/$S".*
    done
    for S in $LIVE; do
      PANE="$("$TMUX_BIN" capture-pane -t "$S" -p -S -40 2>/dev/null | sed 's/[[:space:]]*$//' | grep -v '^$')"
      [ -z "$PANE" ] && continue
      TAIL="$(printf '%s\n' "$PANE" | tail -12)"
      printf '%s' "$TAIL" | grep -vE '^[│>❯ ]*$' | grep -vE 'auto mode on|shift\+tab' | tail -3 | tr '\n' ' ' > "$ST/$S.tail"
      H="$(printf '%s' "$PANE" | shasum | cut -c1-12)"
      # idle tracking: when did this exact screen first appear?
      PREV="$(cat "$ST/$S.hash" 2>/dev/null || true)"; SINCE="$(cat "$ST/$S.since" 2>/dev/null || echo "$NOW")"
      if [ "$PREV" != "$H" ]; then echo "$H" > "$ST/$S.hash"; echo "$NOW" > "$ST/$S.since"; SINCE="$NOW"; fi
      IDLE=$(( NOW - SINCE ))
      WHY=""
      if printf '%s' "$TAIL" | grep -qE 'Enter to confirm|Esc to cancel|Do you want to|Yes, I trust|Yes, and don.t ask|\(y/n\)|\[Y/n\]|\[y/N\]|No, and tell Claude|Allow (once|always)|Press Enter|❯ *1\.|^ *1\. Yes'; then WHY="waiting on a prompt"
      elif [ "$IDLE" -ge 180 ] && printf '%s' "$TAIL" | grep -vE '^[│>❯ ]*$' | tail -1 | grep -q '?$'; then WHY="asked a question and has been idle $((IDLE/60)) min"
      fi
      [ -z "$WHY" ] && continue
      [ "$(cat "$ST/$S.told" 2>/dev/null || true)" = "$H" ] && continue   # already announced this screen
      echo "$H" > "$ST/$S.told"
      SNIP="$(printf '%s' "$TAIL" | grep -vE '^[│>❯ ]*$' | tail -3 | tr '\n' ' ' | cut -c1-220)"
      echo "Session $S is $WHY: $SNIP"
    done
    ;;
  key | keys)
    SESSION="$(resolve_session)"
    [ $# -eq 0 ] && { echo "usage: session.sh key <Enter|Escape|y|1|Down…> [--branch <b>]" >&2; exit 1; }
    "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null || { echo "No running session, dearie." >&2; exit 1; }
    "$TMUX_BIN" send-keys -t "$SESSION" "$@"
    echo "Pressed $* in session $SESSION, dearie."
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
    echo "usage: session.sh read [lines] | send \"<text>\" | key <keys> | needs | list [--branch <b>]" >&2
    exit 1
    ;;
esac
