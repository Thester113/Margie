#!/bin/bash
# slack-watch.sh — one polling cycle of Margie's Slack watcher.
#
# Finds recent messages containing "Margie" and:
#   - live mode (DEFAULT): replies/acts as Tom via the Slack connector.
#   - preview mode:        drafts a reply, sends nothing, notifies Tom.
#
# Dedup is robust and does NOT rely on an LLM-returned timestamp (that bug
# made the watcher advance past real messages and go silent). Instead:
#   1. only look at the last LOOKBACK_MIN minutes,
#   2. skip messages Tom has already replied to (natural dedup in live mode),
#   3. skip messages whose signature is in the local handled list.
set -uo pipefail

MARGIE_DIR="$HOME/.margie"
LOG="$MARGIE_DIR/slack-watch.log"
HANDLED="$MARGIE_DIR/slack-handled.txt"
mkdir -p "$MARGIE_DIR"

MODE="${MARGIE_SLACK_MODE:-live}"
LOOKBACK_MIN="${MARGIE_SLACK_LOOKBACK_MIN:-30}"
NOW="$(date +%s)"

# Prune handled signatures older than 2h, then load recent ones to skip.
if [ -f "$HANDLED" ]; then
  awk -F'|' -v n="$NOW" '($1 + 7200) > n' "$HANDLED" > "$HANDLED.tmp" 2>/dev/null && mv "$HANDLED.tmp" "$HANDLED"
fi
SKIP_LIST="$(cut -d'|' -f2- "$HANDLED" 2>/dev/null | tail -50)"

if [ "$MODE" = "live" ]; then
  ACTION="For each qualifying message, do what it asks or reply helpfully and CONCISELY as Tom's assistant Margie, and actually SEND it in the same channel/DM/thread using Slack tools. If it asks you to message someone else, do that too."
else
  ACTION="For each qualifying message, DRAFT the concise reply you WOULD send as Tom's assistant Margie, but DO NOT send anything. Put the draft in the 'action' field."
fi

PROMPT="You are Margie, Tom's Slack assistant. Using Slack tools:
1. Find messages containing the word 'Margie' posted in the LAST ${LOOKBACK_MIN} MINUTES across Tom's channels and DMs that are:
   - NOT authored by Tom himself, AND
   - NOT already answered (Tom/you have not replied after them), AND
   - NOT matching any of these already-handled snippets:
${SKIP_LIST:-(none yet)}
2. ${ACTION}
3. Output EXACTLY ONE final line of compact JSON and nothing after it:
{\"handled\":[{\"from\":\"name\",\"channel\":\"name\",\"sig\":\"sender: first 40 chars of the message\",\"action\":\"what you did or drafted\"}]}"

echo "=== $(date -u +%FT%TZ) cycle mode=$MODE lookback=${LOOKBACK_MIN}m" >> "$LOG"
OUT="$(cd "$HOME" && claude -p "$PROMPT" --dangerously-skip-permissions --max-turns 16 2>>"$LOG")"
JSON="$(printf '%s' "$OUT" | grep -oE '\{.*\}' | tail -1)"

if [ -z "$JSON" ]; then
  echo "$(date -u +%FT%TZ) mode=$MODE no-json" >> "$LOG"
  exit 0
fi

COUNT="$(printf '%s' "$JSON" | jq -r '(.handled // []) | length' 2>/dev/null || echo 0)"
echo "$(date -u +%FT%TZ) mode=$MODE count=${COUNT:-0} $JSON" >> "$LOG"
[ "${COUNT:-0}" = "0" ] && exit 0

# Record handled signatures so we never re-handle them.
while IFS= read -r sig; do
  [ -n "$sig" ] && echo "${NOW}|${sig}" >> "$HANDLED"
done < <(printf '%s' "$JSON" | jq -r '(.handled // [])[] | .sig // empty' 2>/dev/null)

# macOS notification
SUMMARY="$(printf '%s' "$JSON" | jq -r '(.handled // [])[] | "\(.from): \(.action)"' 2>/dev/null | head -3 | tr '\n' ';')"
TITLE="Margie · Slack"
[ "$MODE" = "preview" ] && TITLE="Margie · Slack (preview — not sent)"
osascript -e "display notification \"${SUMMARY//\"/\'}\" with title \"$TITLE\"" 2>/dev/null || true

# Queue a spoken announcement for the app to say aloud when idle.
SPOKEN="$(printf '%s' "$JSON" | jq -r --arg mode "$MODE" '
  (.handled // []) as $h
  | if ($h | length) == 0 then empty
    else ($h[0].from) as $who
      | "\($who) mentioned you on Slack. "
        + (if $mode == "live" then "I have handled it, sir." else "I have a reply drafted for your approval, sir." end)
        + (if ($h | length) > 1 then " Plus \(($h | length) - 1) more." else "" end)
    end' 2>/dev/null)"
if [ -n "$SPOKEN" ]; then
  mkdir -p "$MARGIE_DIR/announce"
  printf '%s' "$SPOKEN" > "$MARGIE_DIR/announce/$(date +%s%N).txt"
fi
