#!/bin/bash
# slack.sh — Slack via the Web API directly (no Claude, no connector).
#
# Tokens in ~/.margie/config.json (either or both):
#   slack_user_token  xoxp-…  posts AS Tom, can search all his messages/DMs.
#   slack_token       xoxb-…  posts as the "margie" bot; reads/posts only in
#                             channels margie has been /invite-d to. No search,
#                             no DMs (unless im:read/im:history granted).
# A user token is preferred when present (fuller access); otherwise the bot
# token is used with its narrower, membership-scoped capabilities.
#
# Scopes: user token → channels:history groups:history im:history mpim:history
#   channels:read groups:read users:read chat:write search:read.
#   bot token → channels:history groups:read channels:read users:read chat:write
#   (+ invite @margie to each channel she should see/post in).
#
# Usage:
#   slack.sh read ["<query>"]              user token → search; bot → member-channel history (filtered by query)
#   slack.sh send "<#channel|@user|name>: <message>"
#   slack.sh reply "<#channel|@user|name>: <message>"   (alias of send)
set -uo pipefail

CFG="$HOME/.margie/config.json"
UTOK="$(jq -r '.slack_user_token // empty' "$CFG" 2>/dev/null)"
BTOK="$(jq -r '.slack_token // empty' "$CFG" 2>/dev/null)"
# Prefer the user token; fall back to the bot token.
TOKEN="${UTOK:-$BTOK}"
if [ -z "$TOKEN" ]; then
  echo "Slack isn't configured yet, sir — add slack_token (bot) or slack_user_token (user) to ~/.margie/config.json." >&2
  exit 1
fi
case "$TOKEN" in xoxp-*) KIND="user" ;; *) KIND="bot" ;; esac

api() { local method="$1"; shift; curl -sS -H "Authorization: Bearer $TOKEN" "$@" "https://slack.com/api/$method"; }
ok() { jq -e '.ok == true' >/dev/null 2>&1; }

# id → display name cache-ish resolver
uname_of() { api users.info --get --data-urlencode "user=$1" | jq -r '.user.profile.display_name // .user.real_name // .user.name // "?"'; }

cmd="${1:-read}"; shift || true; args="$*"

read_via_search() { # user token only
  local RESP; RESP="$(api search.messages --get --data-urlencode "query=$1" -d "count=15" -d "sort=timestamp")"
  echo "$RESP" | ok || { echo "Slack search failed, sir: $(echo "$RESP" | jq -r '.error // "unknown"')"; return 1; }
  echo "$RESP" | jq -r '.messages.matches[]? | "• #"+(.channel.name // "?")+" — "+(.username // .user // "?")+": "+((.text // "") | gsub("\n";" "))' | head -20
  echo "$RESP" | jq -e '.messages.matches | length>0' >/dev/null 2>&1 || echo "Nothing matching '$1', sir."
}

read_member_channels() { # bot (or user) token: recent history from channels we're in + DMs
  local query="$1" found=0 any_src=0
  # 1) Channels margie is a member of.
  local CONV; CONV="$(api conversations.list --get --data-urlencode "types=public_channel,private_channel" -d "limit=1000" -d "exclude_archived=true")"
  if echo "$CONV" | ok; then
    local members; members="$(echo "$CONV" | jq -r '.channels[]? | select(.is_member==true) | .id+" "+.name')"
    while read -r cid cname; do
      [ -z "$cid" ] && continue
      any_src=1
      local H; H="$(api conversations.history --get --data-urlencode "channel=$cid" -d "limit=8")"
      echo "$H" | ok || continue
      while IFS=$'\t' read -r uid text; do
        [ -z "$text" ] && continue
        echo "• #$cname — $(uname_of "$uid"): $text"; found=1
      done < <(echo "$H" | jq -r --arg q "$query" '.messages[]? | select(.subtype==null) | select($q=="" or (((.text//"")|ascii_downcase) | contains($q|ascii_downcase))) | (.user // "?")+"\t"+((.text // "")|gsub("\n";" "))')
    done <<< "$members"
  fi
  # 2) DMs sent to margie (needs im:read/im:history).
  local IMS; IMS="$(api conversations.list --get --data-urlencode "types=im" -d "limit=50")"
  if echo "$IMS" | ok; then
    while read -r cid uid; do
      [ -z "$cid" ] && continue
      any_src=1
      local H; H="$(api conversations.history --get --data-urlencode "channel=$cid" -d "limit=5")"
      echo "$H" | ok || continue
      local nm; nm="$(uname_of "$uid")"
      while IFS=$'\t' read -r muid text; do
        [ -z "$text" ] && continue
        echo "• DM $nm: $text"; found=1
      done < <(echo "$H" | jq -r --arg q "$query" '.messages[]? | select(.subtype==null) | select($q=="" or (((.text//"")|ascii_downcase) | contains($q|ascii_downcase))) | (.user // "?")+"\t"+((.text // "")|gsub("\n";" "))')
    done < <(echo "$IMS" | jq -r '.channels[]? | .id+" "+(.user // "?")')
  fi
  if [ "$any_src" = "0" ]; then
    echo "I'm not in any channels yet, sir — /invite @margie to the channels you'd like me to watch (DMs to me work already)."
  elif [ "$found" = "0" ]; then
    echo "Nothing recent${query:+ matching '$query'}, sir."
  fi
}

resolve_target() { # -> channel id to post to
  local t="$1" name id
  case "$t" in
    \#*) name="${t#\#}" ;;
    @*)  name="${t#@}"
         local uid; uid="$(api users.list -d "limit=1000" | jq -r --arg n "$name" '.members[]? | select((.name==$n) or (.profile.display_name==$n) or (.real_name==$n)) | .id' | head -1)"
         [ -z "$uid" ] && { echo ""; return; }
         # Prefer an EXISTING DM (only needs im:read); posting there needs just
         # chat:write. Fall back to conversations.open (needs im:write) if none.
         local dm; dm="$(api conversations.list --get --data-urlencode "types=im" -d "limit=1000" | jq -r --arg u "$uid" '.channels[]? | select(.user==$u) | .id' | head -1)"
         [ -n "$dm" ] && { echo "$dm"; return; }
         api conversations.open -d "users=$uid" | jq -r '.channel.id // empty'; return ;;
    *)   name="$t" ;;
  esac
  id="$(api conversations.list --get --data-urlencode "types=public_channel,private_channel" -d "limit=1000" | jq -r --arg n "$name" '.channels[]? | select(.name==$n) | .id' | head -1)"
  echo "$id"
}

case "$cmd" in
  read)
    if [ "$KIND" = "user" ] && [ -n "$args" ]; then
      read_via_search "$args"
    else
      read_member_channels "$args"
    fi
    ;;
  send|reply)
    target="${args%%:*}"; text="${args#*:}"
    target="$(echo "$target" | sed 's/^ *//;s/ *$//')"; text="$(echo "$text" | sed 's/^ *//;s/ *$//')"
    if [ -z "$target" ] || [ -z "$text" ]; then echo "usage: slack.sh $cmd \"<#channel|@user|name>: <message>\"" >&2; exit 1; fi
    cid="$(resolve_target "$target")"
    [ -z "$cid" ] && { echo "Couldn't find '$target' on Slack, sir (bot must be a member of the channel)." >&2; exit 1; }
    RESP="$(api chat.postMessage --get --data-urlencode "channel=$cid" --data-urlencode "text=$text")"
    if echo "$RESP" | ok; then echo "Sent to $target, sir$([ "$KIND" = bot ] && echo " (as the margie bot)").";
    else echo "Send failed, sir: $(echo "$RESP" | jq -r '.error // "unknown"')"; exit 1; fi
    ;;
  *)
    echo "usage: slack.sh read [query] | send \"<target>: msg\" | reply \"<target>: msg\"" >&2
    exit 1
    ;;
esac
