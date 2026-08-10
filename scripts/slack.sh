#!/bin/bash
# slack.sh — Margie's reliable Slack helper.
#
# Margie's own brain can't see the Slack connector, but a `claude -p`
# sub-invocation can (it has Tom's claude.ai connectors). This wraps that in a
# fixed command so the brain just runs one line instead of composing the
# delegation itself. Prints a plain-text result for the brain to relay.
#
# Usage:
#   slack.sh read  [query]                 e.g. slack.sh read "founders"   /  slack.sh read
#   slack.sh send  "<channel/person>: <message>"
#   slack.sh reply "<instruction, e.g. reply to Skyler's DM saying ...>"
set -uo pipefail

CMD="${1:-}"
shift || true
ARGS="$*"

case "$CMD" in
  read)
    if [ -z "$ARGS" ]; then
      TASK="read the most recent messages across my channels and DMs from the last few hours"
    else
      TASK="read the most recent messages matching: $ARGS"
    fi
    PROMPT="Using Slack tools (read-only, send nothing), $TASK. Summarize concisely for the boss: who said what, in which channel. If nothing, say so."
    ;;
  send)
    PROMPT="Using Slack tools, send this Slack message now and confirm it was sent: $ARGS"
    ;;
  reply)
    PROMPT="Using Slack tools, $ARGS. Actually send it, then confirm what you sent and to whom."
    ;;
  *)
    echo "usage: slack.sh {read [query] | send \"#channel: message\" | reply \"instruction\"}" >&2
    exit 1
    ;;
esac

LOG="$HOME/.margie/slack.log"
mkdir -p "$HOME/.margie"
echo "=== $(date -u +%FT%TZ) slack.sh $CMD [$ARGS]" >> "$LOG"
OUT="$(cd "$HOME" && claude -p "$PROMPT" --dangerously-skip-permissions --max-turns 12 2>>"$LOG")"
STATUS=$?
{ echo "exit=$STATUS output:"; echo "$OUT"; echo; } >> "$LOG"
printf '%s' "$OUT"
