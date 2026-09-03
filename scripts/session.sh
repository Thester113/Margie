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
#   session.sh attach [name]                  watch a session here (tmux attach; detach with ctrl-b d)
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
    --session) SESSION_NAME="${2:-}"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}
MARGIE_CLI="$(cd "$(dirname "$0")/.." && pwd)/bin/margie"

resolve_session() {
  local S=""
  if [ -n "${SESSION_NAME:-}" ]; then S="$SESSION_NAME"; echo "$S"; return; fi
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
    NARRATE="$(jq -r '.session_narrate // "on"' "$HOME/.margie/config.json" 2>/dev/null)"
    for S in $LIVE; do
      PANE="$("$TMUX_BIN" capture-pane -t "$S" -p -S -60 2>/dev/null | sed 's/[[:space:]]*$//' | grep -v '^$')"
      [ -z "$PANE" ] && continue
      TAIL="$(printf '%s\n' "$PANE" | tail -12)"
      # PLAY-BY-PLAY: announce each new action the session takes (Claude Code narrates its
      # own steps with ⏺ bullets). Emit the newest bullet when it changes, so Tom follows
      # along without watching the tab. Label the session by its Claude-set window title.
      if [ "$NARRATE" != "off" ] && printf '%s' "$TAIL" | grep -q 'esc to interrupt'; then
        ACT="$(printf '%s' "$PANE" | grep -E '^⏺' | tail -1 | sed 's/^⏺ *//' | cut -c1-160)"
        NOW2="$(date +%s)"
        if [ -n "$ACT" ] && [ "$(cat "$ST/$S.act" 2>/dev/null || true)" != "$ACT" ]; then
          printf '%s' "$ACT" > "$ST/$S.act"; echo "$NOW2" > "$ST/$S.actat"; rm -f "$ST/$S.beat"
          # Claude Code sets the PANE title to a task summary; prefer it, then a PT from
          # a worktree session name, then the window name.
          WLABEL="$("$TMUX_BIN" display -t "$S" -p '#{pane_title}' 2>/dev/null | sed 's/^[^A-Za-z0-9#/]*//; s/^ *//' | cut -c1-40)"
          case "$WLABEL" in ""|bash|zsh|node|*/*|*"$S"*) WLABEL="$(printf '%s' "$S" | grep -oE 'PT-[0-9]+' | head -1)";; esac
          [ -z "$WLABEL" ] && WLABEL="$("$TMUX_BIN" display -t "$S" -p '#{window_name}' 2>/dev/null | sed 's/^[^A-Za-z0-9#/]*//; s/^ *//' | cut -c1-40)"
          case "$WLABEL" in ""|bash|zsh|node) WLABEL="$S";; esac
          echo "[$WLABEL] $ACT"
        elif [ -n "$ACT" ]; then
          # same action for a while — reassure with a heartbeat every ~2 min so it isn't read as hung
          AAT="$(cat "$ST/$S.actat" 2>/dev/null || echo "$NOW2")"; MINS=$(( (NOW2 - AAT) / 60 ))
          LASTBEAT="$(cat "$ST/$S.beat" 2>/dev/null || echo 0)"
          if [ "$MINS" -ge 2 ] && [ $(( NOW2 - LASTBEAT )) -ge 120 ]; then
            echo "$NOW2" > "$ST/$S.beat"
            WLABEL="$("$TMUX_BIN" display -t "$S" -p '#{pane_title}' 2>/dev/null | sed 's/^[^A-Za-z0-9#/]*//; s/^ *//' | cut -c1-40)"; [ -z "$WLABEL" ] && WLABEL="$S"
            echo "[$WLABEL] still working (${MINS}m): $ACT"
          fi
        fi
      fi
      printf '%s' "$TAIL" | grep -vE '^[│>❯ ]*$|^ *───|Update installed' | grep -vE 'auto mode on|shift\+tab' | tail -3 | tr '\n' ' ' > "$ST/$S.tail"
      H="$(printf '%s' "$PANE" | shasum | cut -c1-12)"
      # idle tracking: when did this exact screen first appear?
      PREV="$(cat "$ST/$S.hash" 2>/dev/null || true)"; SINCE="$(cat "$ST/$S.since" 2>/dev/null || echo "$NOW")"
      if [ "$PREV" != "$H" ]; then echo "$H" > "$ST/$S.hash"; echo "$NOW" > "$ST/$S.since"; SINCE="$NOW"; fi
      IDLE=$(( NOW - SINCE ))
      WHY=""
      # A deploy-watcher session's verdict is announced cleanly, once.
      VERDICT="$(printf '%s' "$PANE" | grep -iE 'DEPLOY VERDICT:' | tail -1 | sed 's/.*DEPLOY VERDICT:/DEPLOY VERDICT:/' | cut -c1-200)"
      if [ -n "$VERDICT" ] && [ "$(cat "$ST/$S.verdict" 2>/dev/null || true)" != "$VERDICT" ]; then
        printf '%s' "$VERDICT" > "$ST/$S.verdict"; echo "$VERDICT"; continue
      fi
      # Claude Code's chrome (status bar, separators, the input box, update banner) is not content.
      CONTENT="$(printf '%s' "$TAIL" | grep -vE '^[│>❯ ]*$|^ *⏵⏵|^ *───|Update installed|esc to interrupt|^ *❯' )"
      LAST="$(printf '%s' "$CONTENT" | tail -3 | tr '\n' ' ')"   # a question often wraps over 2-3 terminal lines
      WORKING=0; printf '%s' "$TAIL" | grep -q "esc to interrupt" && WORKING=1
      # Rescue a stuck send: Claude Code sometimes leaves an injected instruction sitting
      # in the input box without submitting it (paste-detection state). If the composer
      # holds freeform text while the session is idle, re-submit it once via clear-and-retype.
      COMPOSER="$(printf '%s' "$PANE" | grep -E '^❯ ' | tail -1 | sed 's/^❯[[:space:]]*//; s/[[:space:]]*$//')"
      if [ "$WORKING" = 0 ] && [ -n "$COMPOSER" ] && [ "$IDLE" -ge 20 ] \
         && ! printf '%s' "$COMPOSER" | grep -qE '^[0-9]+\.|^(Yes|No)\b' \
         && ! printf '%s' "$TAIL" | grep -qE 'Enter to confirm|Esc to cancel|Do you want to|Yes, I trust|Allow (once|always)|\(y/n\)|\[Y/n\]|\[y/N\]|❯ *1\.'; then
        RH="resub:$(printf '%s' "$COMPOSER" | shasum | cut -c1-12)"
        if [ "$(cat "$ST/$S.told" 2>/dev/null || true)" != "$RH" ]; then
          echo "$RH" > "$ST/$S.told"
          "$TMUX_BIN" send-keys -t "$S" C-u 2>/dev/null; sleep 0.3
          "$TMUX_BIN" send-keys -t "$S" -l -- "$COMPOSER"; sleep 0.5
          "$TMUX_BIN" send-keys -t "$S" Enter; sleep 1
          if "$TMUX_BIN" capture-pane -t "$S" -p 2>/dev/null | grep -E '^❯ ' | tail -1 | grep -qF "$(printf '%s' "$COMPOSER" | cut -c1-24)"; then
            echo "[$S] has an instruction stuck in its input I couldn't submit — needs a look: $(printf '%s' "$COMPOSER" | cut -c1-80)"
          else
            echo "[$S] had an instruction stuck unsent — I submitted it: $(printf '%s' "$COMPOSER" | cut -c1-80)"
          fi
          continue
        fi
      fi
      if printf '%s' "$TAIL" | grep -qE 'Enter to confirm|Esc to cancel|Do you want to|Yes, I trust|Yes, and don.t ask|\(y/n\)|\[Y/n\]|\[y/N\]|No, and tell Claude|Allow (once|always)|Press Enter|❯ *1\.|^ *1\. Yes'; then WHY="waiting on a prompt"
      elif [ "$WORKING" = 0 ] && [ "$IDLE" -ge 45 ] && printf '%s' "$PANE" | tail -12 | grep -qE '· done [0-9]' && printf '%s' "$CONTENT" | grep -qiE 'still needed|next steps?|remaining|what is left|to finish|blocked on|needs? (you|tom)|could not|did not|unable|flag for tom|ready (for|to) (tom|review|submit)|filled and ready|review and submit|for tom to'; then WHY="finished its task and reported what is still needed"
      elif [ "$WORKING" = 0 ] && [ "$IDLE" -ge 120 ] && printf '%s' "$LAST" | grep -qiE '\?|\b(shall i|should i|want me to|would you like|let me know|say the word|ready to|waiting for|tell me)\b'; then WHY="asked a question and has been idle $((IDLE/60)) min"
      fi
      [ -z "$WHY" ] && continue
      # Tom's explicit instruction (2026-09-03): Margie answers the session's permission
      # prompts as him (config session_autoanswer, default true). Only prompts that look
      # genuinely dangerous — force pushes, history resets, secrets, deploys, privilege
      # escalation, piping downloads into a shell — are escalated to him instead.
      if [ "$WHY" = "waiting on a prompt" ] && [ "$(jq -r '.session_autoanswer // true' "$HOME/.margie/config.json" 2>/dev/null)" = true ]; then
        if printf '%s' "$TAIL" | grep -qiE 'push[^|]*--force|force-?push|reset --hard|--no-verify|DROP (TABLE|DATABASE)|deploy|production|secrets?|credential|\.env\b|sudo|chmod 777|curl[^|]*\| *(ba)?sh|rm -rf /'; then
          WHY="waiting on a prompt I will NOT answer for you (it looks dangerous)"
        elif printf '%s' "$TAIL" | grep -qE 'Yes, I trust'; then
          "$TMUX_BIN" send-keys -t "$S" Down; sleep 0.3; "$TMUX_BIN" send-keys -t "$S" Enter
          echo "$H" > "$ST/$S.told"; echo "Session $S asked to trust its folder — answered yes for you."; continue
        elif printf '%s' "$TAIL" | grep -qE '❯ *1\.|^ *1\. Yes|Do you want to'; then
          "$TMUX_BIN" send-keys -t "$S" 1; sleep 0.3; "$TMUX_BIN" send-keys -t "$S" Enter
          echo "$H" > "$ST/$S.told"; echo "Session $S asked permission ($(printf '%s' "$TAIL" | grep -vE '^[│>❯ ]*$' | grep -iE 'want to|proceed|allow|run' | head -1 | cut -c1-120)) — answered yes for you."; continue
        elif printf '%s' "$TAIL" | grep -qE '\(y/n\)|\[Y/n\]|\[y/N\]'; then
          "$TMUX_BIN" send-keys -t "$S" y Enter
          echo "$H" > "$ST/$S.told"; echo "Session $S asked y/n — answered yes for you."; continue
        fi
      fi
      SNIP="$(printf '%s' "$CONTENT" | grep -vE 'auto mode on|shift\+tab|⏵⏵|/rc|Explore|Listing|^ *[●○]|MARGIE_READY_FOR_QA|MARGIE_MR_|print MARGIE' | sed 's/[─│┌┐└┘┤├┬┴┼▶►◀]//g; s/[^[:print:][:space:]]//g' | grep -vE '^[[:space:]]*$' | tail -2 | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-200)"
      SIG="$(printf '%s|%s' "$WHY" "$SNIP" | shasum | cut -c1-12)"
      [ "$(cat "$ST/$S.told" 2>/dev/null || true)" = "$SIG" ] && continue   # already announced this state (not once per screen-clock tick)
      echo "$SIG" > "$ST/$S.told"
      # A session that asked a question gets its answer from Margie's brain — she knows the
      # project notes and conventions. She escalates only money, credentials or product calls.
      if printf '%s' "$WHY" | grep -qE "asked a question|finished its task" && [ -x "$MARGIE_CLI" ] && [ "$(jq -r '.session_autoanswer // true' "$HOME/.margie/config.json" 2>/dev/null)" = true ]; then
        Q="$(printf '%s' "$CONTENT" | tail -25)"
        ASK="$(cat <<'EOT'
SESSION QUESTION/REPORT. A coding session stopped; its last lines follow. Decide the next step yourself: (a) if it asked something you can answer from the notes and conventions (names, versions, defaults, order, what Tom decided), answer it with session.sh send "<answer>" --session SESSION_NAME; (b) if it finished and listed what is still needed, do the next item yourself when a helper covers it (telnyx.sh, notion.sh, dispatch.sh…) or send the next instruction into the session; then reply with one line saying what you did. If the next step needs money you have no standing to spend, credentials, or a product decision Tom has not made, do nothing and reply exactly: ESCALATE: <one-line ask for Tom>. Never leave a session idle with work left.
EOT
)"
        ASK="${ASK//SESSION_NAME/$S}"
        ANS="$(MARGIE_SOURCE=session "$MARGIE_CLI" -q "$ASK
---
$Q" 2>/dev/null)"
        case "$ANS" in
          ESCALATE:*) echo "Session $S needs Tom: ${ANS#ESCALATE:}" ;;
          "") echo "Session $S $WHY: $SNIP" ;;
          *) echo "Session $S asked a question — I answered it: $(printf '%s' "$ANS" | head -1 | cut -c1-200)" ;;
        esac
        continue
      fi
      echo "Session $S is $WHY: $SNIP"
    done
    ;;
  attach | watch)
    SESSION="$(resolve_session)"; [ -n "${1:-}" ] && SESSION="$1"
    "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null || { echo "No session '$SESSION', dearie. Live: $("$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null | grep '^margie' | tr '\n' ' ')" >&2; exit 1; }
    exec "$TMUX_BIN" attach -t "$SESSION" ;;
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
    # Collapse to a single line: a multi-line block is treated as a paste attachment
    # by Claude Code and a lone Enter won't submit it (it gets stuck in the input box).
    # Also fold non-ASCII punctuation (em/en dashes, smart quotes) down to ASCII: sending
    # multibyte characters through `tmux send-keys -l` is what wedges the composer so that
    # neither Enter nor C-u can recover it.
    ONE="$(printf '%s' "$TEXT" | perl -CSD -0777 -pe 's/[\x{2012}-\x{2015}]/-/g; s/[\x{2018}\x{2019}]/'"'"'/g; s/[\x{201C}\x{201D}]/"/g; s/\s+/ /g; s/^\s+|\s+$//g' 2>/dev/null)"
    [ -z "$ONE" ] && ONE="$(printf '%s' "$TEXT" | tr '\n' ' ' | sed 's/  */ /g')"
    # Fixed-string probe (no regex — the text may contain em-dashes, slashes, etc.).
    PROBE="$(printf '%s' "$ONE" | cut -c1-24)"
    # True when our text is NO LONGER sitting in the composer (i.e. it submitted).
    submitted() { ! "$TMUX_BIN" capture-pane -t "$SESSION" -p 2>/dev/null | grep -E '^❯' | tail -1 | grep -qF "$PROBE"; }
    # One full clear-and-retype cycle. A bare Enter cannot rescue text once Claude
    # Code has it in paste/attachment state — only clearing (C-u) and retyping does.
    submit_once() {
      "$TMUX_BIN" send-keys -t "$SESSION" C-u 2>/dev/null   # clear anything half-typed/stuck
      sleep 0.3
      "$TMUX_BIN" send-keys -t "$SESSION" -l -- "$ONE"
      sleep 0.5; "$TMUX_BIN" send-keys -t "$SESSION" Enter
      sleep 1.0; submitted
    }
    OK=0
    for _try in 1 2 3; do if submit_once; then OK=1; break; fi; sleep 0.5; done
    if [ "$OK" = 1 ]; then
      echo "Sent into session $SESSION, dearie."
    else
      echo "Couldn't submit into $SESSION — the text stayed stuck in the composer, dearie." >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: session.sh read [lines] | send \"<text>\" | key <keys> | needs | list [--branch <b>]" >&2
    exit 1
    ;;
esac
