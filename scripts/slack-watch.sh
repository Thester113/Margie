#!/bin/bash
# slack-watch.sh — one polling cycle of Margie's Slack @mention watcher.
#
# Detects real @Margie mentions (the bot's `<@BOTID>` token) in the channels the
# margie bot is a member of, plus any DM sent to the bot, and:
#   - live mode (DEFAULT): replies in-thread AS @Margie (the bot), running Claude
#     Code headless to compose. Claude is invoked ONLY when there's a new mention, so idle
#     cycles are free (just a couple of Slack reads — no model usage).
#   - preview mode:        drafts the reply, posts nothing, notifies Tom.
#
# Runs on the direct Slack bot token + `claude -p` (no connector).
# Dedup is by message ts in a local handled list (no LLM-returned timestamps).
set -uo pipefail

MARGIE_DIR="$HOME/.margie"
LOG="$MARGIE_DIR/slack-watch.log"
HANDLED="$MARGIE_DIR/slack-handled.txt"
mkdir -p "$MARGIE_DIR"

MODE="${MARGIE_SLACK_MODE:-live}"
NOW="$(date +%s)"
# Replies are composed by Claude Code in headless mode (-p). The watcher answers
# ANYONE who @mentions Margie, so it must be purely conversational: every tool is
# stripped so a Slack user can't make her run scripts, snap the webcam, read Tom's
# screen, or take any action. Cheap model by default.
CLAUDE_BIN="${MARGIE_CLAUDE_BIN:-$(command -v claude || echo "$HOME/.local/bin/claude")}"
CMODEL="${MARGIE_SLACK_MODEL:-haiku}"
CLAUDE_GUARDS=(--disallowedTools "Bash,Edit,Write,NotebookEdit,Agent,WebFetch,WebSearch,Read,Glob,Grep")

BTOK="$(jq -r '.slack_token // empty' "$MARGIE_DIR/config.json" 2>/dev/null)"
if [ -z "$BTOK" ]; then echo "$(date -u +%FT%TZ) no slack_token" >> "$LOG"; exit 0; fi
sapi() { local m="$1"; shift; curl -sS -H "Authorization: Bearer $BTOK" "$@" "https://slack.com/api/$m"; }

BOTID="$(sapi auth.test | jq -r '.user_id // empty')"
[ -z "$BOTID" ] && { echo "$(date -u +%FT%TZ) auth.test failed" >> "$LOG"; exit 0; }
MENTION="<@${BOTID}>"

# Prune handled ts older than 6h.
if [ -f "$HANDLED" ]; then
  awk -F'|' -v n="$NOW" '($1 + 21600) > n' "$HANDLED" > "$HANDLED.tmp" 2>/dev/null && mv "$HANDLED.tmp" "$HANDLED"
fi
already() { grep -qF "|$1" "$HANDLED" 2>/dev/null; }

echo "=== $(date -u +%FT%TZ) cycle mode=$MODE bot=$BOTID" >> "$LOG"

# Collect (channel_id, channel_label, ts, thread_ts, user, text) for new mentions.
# Channels the bot is a member of → look for the mention token.
# DMs to the bot → every non-bot message counts (an implicit mention).
SRCS="$(mktemp)"
{
  sapi conversations.list --get --data-urlencode "types=public_channel,private_channel" -d "limit=1000" -d "exclude_archived=true" \
    | jq -r '.channels[]? | select(.is_member==true) | "chan\t"+.id+"\t#"+.name'
  sapi conversations.list --get --data-urlencode "types=im" -d "limit=200" \
    | jq -r '.channels[]? | "im\t"+.id+"\tDM"' 2>/dev/null
} > "$SRCS"

NEW="$(mktemp)"
while IFS=$'\t' read -r kind cid label; do
  [ -z "$cid" ] && continue
  H="$(sapi conversations.history --get --data-urlencode "channel=$cid" -d "limit=15")"
  echo "$H" | jq -e '.ok==true' >/dev/null 2>&1 || continue
  # For channels, require the mention token; for DMs, any message not from the bot.
  echo "$H" | jq -r --arg bot "$BOTID" --arg men "$MENTION" --arg kind "$kind" --arg cid "$cid" --arg label "$label" '
    .messages[]?
    | select(.subtype==null) | select((.user // "") != $bot)
    | select($kind=="im" or ((.text // "") | contains($men)))
    | [$cid, $label, .ts, (.thread_ts // .ts), (.user // "?"), ((.text // "") | gsub("\t";" ") | gsub("\n";" "))]
    | @tsv' >> "$NEW"
done < "$SRCS"
rm -f "$SRCS"

# Filter out already-handled ts.
COUNT=0
: > "$NEW.todo"
while IFS=$'\t' read -r cid label ts thread user text; do
  [ -z "$ts" ] && continue
  already "$ts" && continue
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$cid" "$label" "$ts" "$thread" "$user" "$text" >> "$NEW.todo"
  COUNT=$((COUNT+1))
done < "$NEW"

if [ "$COUNT" = "0" ]; then
  echo "$(date -u +%FT%TZ) no new mentions" >> "$LOG"
  rm -f "$NEW" "$NEW.todo"; exit 0
fi
echo "$(date -u +%FT%TZ) $COUNT new mention(s)" >> "$LOG"

uname_of() { sapi users.info --get --data-urlencode "user=$1" | jq -r '.user.profile.display_name // .user.real_name // .user.name // "?"'; }

FIRST_WHO=""; MORE=0
while IFS=$'\t' read -r cid label ts thread user text; do
  who="$(uname_of "$user")"
  [ -z "$FIRST_WHO" ] && FIRST_WHO="$who" || MORE=$((MORE+1))
  clean="$(printf '%s' "$text" | sed "s/$MENTION//g" | sed 's/^ *//;s/ *$//')"
  P="You are Margie, Tom's assistant, replying in a PUBLIC Slack channel AS the Margie bot. $who said: \"$clean\". Reply helpfully and concisely in one or two short sentences, in WORDS ONLY. Do NOT run any command or script; do NOT access Tom's screen, camera, files, email, calendar, or any system; do NOT take any action or send anything anywhere. If they ask for an action or anything only Tom should decide, say you'll flag it for Tom. Output ONLY the message text to post — no preamble."
  REPLY="$(cd "$HOME" && "$CLAUDE_BIN" -p "$P" --model "$CMODEL" "${CLAUDE_GUARDS[@]}" 2>>"$LOG" | sed 's/^ *//;s/ *$//')"
  [ -z "$REPLY" ] && REPLY="Hello, sir — Margie here."
  if [ "$MODE" = "live" ]; then
    POST="$(sapi chat.postMessage --get --data-urlencode "channel=$cid" --data-urlencode "thread_ts=$thread" --data-urlencode "text=$REPLY")"
    if echo "$POST" | jq -e '.ok==true' >/dev/null 2>&1; then
      echo "$(date -u +%FT%TZ) replied in $label ts=$ts" >> "$LOG"
    else
      echo "$(date -u +%FT%TZ) post failed in $label: $(echo "$POST"|jq -r '.error//"?"')" >> "$LOG"
    fi
  else
    echo "$(date -u +%FT%TZ) DRAFT for $label: $REPLY" >> "$LOG"
  fi
  echo "${NOW}|${ts}" >> "$HANDLED"
done < "$NEW.todo"
rm -f "$NEW" "$NEW.todo"

# macOS notification + spoken announce — phrased from Margie's point of view
# (she is speaking TO Tom, so it's about HER being mentioned, not "you").
# Name the mentioner only when it isn't Tom himself.
case "$FIRST_WHO" in
  Tom | "Tom Hester" | tom) BY="" ;;
  *) BY=" by $FIRST_WHO" ;;
esac
if [ "$MODE" = "live" ]; then TAIL="and I've replied, sir."; else TAIL="and I have a draft for your approval, sir."; fi
SPOKEN="I've been mentioned on Slack$BY, $TAIL"
[ "$MORE" -gt 0 ] && SPOKEN="$SPOKEN Plus $MORE more."
TITLE="Margie · Slack"; [ "$MODE" = "preview" ] && TITLE="Margie · Slack (preview — not sent)"
osascript -e "display notification \"${SPOKEN//\"/\'}\" with title \"$TITLE\"" 2>/dev/null || true
mkdir -p "$MARGIE_DIR/announce"
printf '%s' "$SPOKEN" > "$MARGIE_DIR/announce/$(date +%s%N).txt"
