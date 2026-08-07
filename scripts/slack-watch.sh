#!/bin/bash
# slack-watch.sh — one polling cycle of Margie's Slack watcher.
#
# Finds NEW messages containing "Margie" (since the last checked time) and:
#   - preview mode (default): DRAFTS a reply, sends nothing, notifies Tom.
#   - live mode:              REPLIES/acts as Tom via the Slack connector.
#
# Mode is MARGIE_SLACK_MODE=preview|live (default preview). State (last-seen
# timestamp) is tracked so old messages are never re-handled.
set -uo pipefail

MARGIE_DIR="$HOME/.margie"
STATE="$MARGIE_DIR/slack-watch-since.txt"
LOG="$MARGIE_DIR/slack-watch.log"
mkdir -p "$MARGIE_DIR"

MODE="${MARGIE_SLACK_MODE:-preview}"

# On first run, start from "now" so Margie doesn't reply to the whole backlog.
SINCE="$(cat "$STATE" 2>/dev/null || true)"
if [ -z "$SINCE" ]; then
  SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "$SINCE" > "$STATE"
fi

if [ "$MODE" = "live" ]; then
  ACTION="For each new message, do what it asks or reply helpfully and CONCISELY as Tom's assistant Margie, and actually SEND it in the same channel/DM/thread using Slack tools. If it asks you to message someone else, do that too. Sign nothing; just be helpful and brief."
else
  ACTION="For each new message, DRAFT the concise reply you WOULD send as Tom's assistant Margie, but DO NOT send anything. Put the draft text in the 'action' field."
fi

PROMPT="You are Margie, Tom's Slack assistant, monitoring his Slack. Using Slack tools:
1. Find messages containing the word 'Margie' posted strictly AFTER ${SINCE} (UTC), across Tom's channels and DMs, that are NOT authored by Tom himself and that have not already been answered after that message.
2. ${ACTION}
3. Then output EXACTLY ONE final line of compact JSON and nothing after it:
{\"handled\":[{\"from\":\"name\",\"channel\":\"name\",\"text\":\"original message\",\"action\":\"what you did or drafted\"}],\"newest\":\"ISO8601-UTC of the newest message you handled, or ${SINCE} if none\"}"

OUT="$(cd "$HOME" && claude -p "$PROMPT" --dangerously-skip-permissions --max-turns 14 2>/dev/null)"
JSON="$(printf '%s' "$OUT" | grep -oE '\{.*\}' | tail -1)"

if [ -z "$JSON" ]; then
  echo "$(date -u +%FT%TZ) mode=$MODE no-json" >> "$LOG"
  exit 0
fi

NEWEST="$(printf '%s' "$JSON" | jq -r '.newest // empty' 2>/dev/null || true)"
COUNT="$(printf '%s' "$JSON" | jq -r '(.handled // []) | length' 2>/dev/null || echo 0)"
[ -n "$NEWEST" ] && echo "$NEWEST" > "$STATE"
echo "$(date -u +%FT%TZ) mode=$MODE count=${COUNT:-0} $JSON" >> "$LOG"

if [ "${COUNT:-0}" != "0" ]; then
  SUMMARY="$(printf '%s' "$JSON" | jq -r '(.handled // [])[] | "\(.from): \(.action)"' 2>/dev/null | head -3 | tr '\n' ';' )"
  TITLE="Margie · Slack"
  [ "$MODE" = "preview" ] && TITLE="Margie · Slack (preview — not sent)"
  osascript -e "display notification \"${SUMMARY//\"/\'}\" with title \"$TITLE\"" 2>/dev/null || true

  # Queue a spoken announcement for the app to say aloud when idle.
  SPOKEN="$(printf '%s' "$JSON" | jq -r --arg mode "$MODE" '
    (.handled // []) as $h
    | if ($h | length) == 0 then empty
      else
        ($h[0].from) as $who
        | "\($who) mentioned you on Slack. "
          + (if $mode == "live" then "I have handled it, sir." else "I have a reply drafted for your approval, sir." end)
          + (if ($h | length) > 1 then " Plus \(($h | length) - 1) more." else "" end)
      end' 2>/dev/null)"
  if [ -n "$SPOKEN" ]; then
    mkdir -p "$MARGIE_DIR/announce"
    printf '%s' "$SPOKEN" > "$MARGIE_DIR/announce/$(date +%s%N).txt"
  fi
fi
