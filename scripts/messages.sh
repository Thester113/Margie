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
#   messages.sh list                      list recent chat names (to find a handle)
#   messages.sh resolve "<who>"           show what an alias/name resolves to
set -uo pipefail

CFG="$HOME/.margie/config.json"
cmd="${1:-}"; shift || true

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
      echo "Sent to $who ($target), sir: \"$msg\""
    else
      echo "Couldn't send to $who ($target), sir: ${out:0:160}. Is the handle a phone/email? Set an alias in config.contacts." >&2
      exit 1
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
