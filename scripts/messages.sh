#!/bin/bash
# messages.sh — send iMessage/SMS reliably and list chats, so Margie never has
# to improvise AppleScript (which sent to the wrong person).
#
# Contact aliases live in ~/.margie/config.json under "contacts", mapping a
# spoken name to a phone/email handle (most reliable) or exact contact name:
#   "contacts": { "wife": "+15551234567", "mom": "jane@icloud.com" }
#
# Usage:
#   messages.sh send "<who>: <message>"   who = alias | phone/email | contact name
#   messages.sh read "<who>" [count]      read recent 1:1 iMessages (voice memos
#                                         transcribed). Needs Full Disk Access.
#   messages.sh groups                    list group chats by members (newest first)
#   messages.sh readchat <chat_id> [n]    read a group chat (senders + transcripts)
#   messages.sh sendchat <chat_id> "<m>"  send to a GROUP chat (never use `send`)
#   messages.sh list                      list recent chat handles
#   messages.sh resolve "<who>"           show what an alias/name resolves to
set -uo pipefail

CFG="$HOME/.margie/config.json"
cmd="${1:-}"; shift || true
DIR="$(cd "$(dirname "$0")" && pwd)"
DB="$HOME/Library/Messages/chat.db"

need_db() {
  [ -r "$DB" ] && return 0
  echo "I can't read Messages, dear — grant Full Disk Access to the app (System Settings → Privacy & Security → Full Disk Access), then try again." >&2
  exit 1
}

resolve() {
  local who="$1" key val
  key="$(printf '%s' "$who" | tr 'A-Z' 'a-z' | sed 's/^ *//;s/ *$//')"
  # 1) alias in config.contacts (case-insensitive)
  val="$(jq -r --arg k "$key" '(.contacts // {}) | to_entries[] | select((.key|ascii_downcase)==$k) | .value' "$CFG" 2>/dev/null | head -1)"
  [ -n "$val" ] && { printf '%s' "$val"; return; }
  # 2) otherwise use it as given (a phone/email handle or contact name)
  printf '%s' "$who"
}

case "$cmd" in
  send)
    args="$*"
    who="${args%%:*}"; msg="${args#*:}"
    who="$(printf '%s' "$who" | sed 's/^ *//;s/ *$//')"
    msg="$(printf '%s' "$msg" | sed 's/^ *//;s/ *$//')"
    if [ -z "$who" ] || [ -z "$msg" ] || [ "$who" = "$args" ]; then
      echo "usage: messages.sh send \"<who>: <message>\"" >&2; exit 1
    fi
    target="$(resolve "$who")"
    # Escape double quotes and backslashes for AppleScript string literals.
    esc_msg="$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    esc_tgt="$(printf '%s' "$target" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    out="$(osascript <<OSA 2>&1
tell application "Messages"
  set svc to 1st account whose service type = iMessage
  try
    set b to participant "$esc_tgt" of svc
  on error
    set b to buddy "$esc_tgt" of svc
  end try
  send "$esc_msg" to b
end tell
OSA
)"
    if [ $? -eq 0 ]; then
      echo "Sent to $who ($target), dear: \"$msg\""
    else
      echo "Couldn't send to $who ($target), dear: ${out:0:160}. Is the handle a phone/email? Set an alias in config.contacts." >&2
      exit 1
    fi
    ;;
  read)
    # Recent 1:1 iMessages with someone (voice memos auto-transcribed). Needs
    # Full Disk Access for the running app.
    who="$1"; shift || true; N="${1:-12}"
    [ -z "$who" ] && { echo "usage: messages.sh read \"<who>\" [count]" >&2; exit 1; }
    need_db
    python3 "$DIR/imsg_read.py" handle "$(resolve "$who")" "$N"
    ;;
  groups)
    # List group chats (unnamed groups shown by members), so the brain/Tom can
    # find the right one — e.g. the group containing wifey. Prints: <chat_id> · <members> · <last active>
    need_db
    # Subqueries (not joins) so members aren't multiplied by message count.
    sqlite3 "file:$DB?mode=ro" "
      SELECT c.ROWID || char(9) ||
        (SELECT group_concat(h.id, ', ') FROM chat_handle_join chj
           JOIN handle h ON chj.handle_id=h.ROWID WHERE chj.chat_id=c.ROWID) || char(9) ||
        COALESCE((SELECT datetime(MAX(m.date)/1000000000 + 978307200,'unixepoch','localtime')
           FROM chat_message_join cmj JOIN message m ON m.ROWID=cmj.message_id
           WHERE cmj.chat_id=c.ROWID),'')
      FROM chat c
      WHERE (SELECT COUNT(*) FROM chat_handle_join WHERE chat_id=c.ROWID) >= 2
      ORDER BY (SELECT MAX(m.date) FROM chat_message_join cmj
                  JOIN message m ON m.ROWID=cmj.message_id WHERE cmj.chat_id=c.ROWID) DESC
      LIMIT 20;" 2>/dev/null \
      | while IFS=$'\t' read -r id members last; do
          # Swap known handles for their aliases for readability.
          jq -r --arg m "$members" '(.contacts // {}) as $c
            | ($m | split(", ") | map(. as $h | ($c | to_entries[] | select(.value==$h) | .key) // $h) | join(", "))' "$CFG" 2>/dev/null \
            | { read -r pretty; echo "chat $id · ${pretty:-$members} · ${last}"; }
        done
    ;;
  readchat)
    # Read recent messages from a group chat by its id (from `groups`).
    id="$1"; shift || true; N="${1:-15}"
    [ -z "$id" ] && { echo "usage: messages.sh readchat <chat_id> [count]  (see: messages.sh groups)" >&2; exit 1; }
    need_db
    python3 "$DIR/imsg_read.py" chat "$id" "$N"
    ;;
  sendchat)
    # Send to a GROUP chat by its id (the number from `groups`/`readchat`).
    # NEVER use `send` for a group — that treats the id as a person and fails.
    id="$1"; shift || true; msg="$*"
    if [ -z "$id" ] || [ -z "$msg" ]; then
      echo "usage: messages.sh sendchat <chat_id> \"<message>\"  (chat_id from: messages.sh groups)" >&2; exit 1
    fi
    # A bare number is a chat ROWID → look up its guid; a "…;…;…" value is a guid already.
    case "$id" in
      *\;*) guid="$id" ;;
      *) need_db; guid="$(sqlite3 "file:$DB?mode=ro" "SELECT guid FROM chat WHERE ROWID=$id;" 2>/dev/null)" ;;
    esac
    [ -z "$guid" ] && { echo "No group chat with id $id, dear — run messages.sh groups to find it." >&2; exit 1; }
    esc_msg="$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    esc_guid="$(printf '%s' "$guid" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    out="$(osascript -e "tell application \"Messages\" to send \"$esc_msg\" to chat id \"$esc_guid\"" 2>&1)"
    if [ $? -eq 0 ]; then
      echo "Sent to the group (chat $id), dear: \"$msg\""
    else
      echo "Couldn't send to the group (chat $id), dear: ${out:0:160}" >&2; exit 1
    fi
    ;;
  list)
    # Chat ids embed the handle (e.g. "iMessage;-;+15551234567"); pull out the
    # phone numbers / emails so Tom can pick one to set as an alias.
    {
      osascript -e 'tell application "Messages" to get id of every chat' 2>/dev/null
      osascript -e 'tell application "Messages" to get name of every chat' 2>/dev/null
    } | tr ',' '\n' \
      | grep -oE '[+][0-9]{7,}|[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}|[A-Z][a-zA-Z ]{2,30}' \
      | grep -v 'missing value' | sed 's/^ *//;s/ *$//' | sort -u | head -40
    ;;
  resolve)
    echo "$(resolve "$*")"
    ;;
  *)
    echo "usage: messages.sh send \"<who>: <msg>\" | list | resolve \"<who>\"" >&2
    exit 1
    ;;
esac
