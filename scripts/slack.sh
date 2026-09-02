#!/bin/bash
# slack.sh — Slack for Margie. Two backends:
#   1) direct Slack Web API when a token is in ~/.margie/config.json (below), or
#   2) Claude Code's Slack connector (the claude.ai Slack app) via headless
#      `claude -p` with only the needed Slack tools allowed — the default when no
#      token is configured, or when config has "slack_via": "claude".
#
# Tokens for backend 1 in ~/.margie/config.json (either or both):
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
VIA="$(jq -r '.slack_via // empty' "$CFG" 2>/dev/null)"
SEND_AS="$(jq -r '.slack_send_as // empty' "$CFG" 2>/dev/null)"
# Sends default to the @Margie BOT identity whenever a bot token exists
# (slack_send_as: "tom" reverts to sending as Tom via the connector/user token).
BOT_SEND=0
case "${1:-read}" in
  send|reply|dm) [ -n "$BTOK" ] && [ "$SEND_AS" != "tom" ] && { BOT_SEND=1; TOKEN="$BTOK"; } ;;
esac

# ── Backend 2: Claude Code's Slack connector (the claude.ai Slack app) ──────────
# Used when no raw token is configured, or slack_via is "claude". Each call is a
# headless `claude -p` with ONLY the Slack tools it needs allowed, so Claude acts
# as Tom in Slack through the connector — no token to manage here.
if [ "$BOT_SEND" = 0 ] && { [ -z "$TOKEN" ] || [ "$VIA" = "claude" ]; }; then
  CLAUDE_BIN="${MARGIE_CLAUDE_BIN:-$(command -v claude || echo "$HOME/.local/bin/claude")}"
  CMODEL="${MARGIE_SLACK_MODEL:-sonnet}"
  T="mcp__claude_ai_Slack__"
  ask() { # ask "<prompt>" <allowed tools csv>
    local out; out="$(cd "$HOME" && "$CLAUDE_BIN" -p "$1" --model "$CMODEL" --output-format json --allowedTools "$2" 2>/dev/null | jq -r '.result // empty')"
    [ -n "$out" ] && printf '%s\n' "$out" || { echo "Slack via Claude returned nothing, dearie — is the Slack connector connected (claude mcp list)?" >&2; return 1; }
  }
  cmd="${1:-read}"; shift || true; args="$*"
  case "$cmd" in
    read|search|unread)
      if [ -n "$args" ]; then Q="Search Tom's Slack for: $args."; else Q="Show Tom's most recent DMs and @mentions (last day or so)."; fi
      ask "You are Margie's Slack reader; Tom's replies are spoken aloud, so be terse. $Q Use slack_search_public_and_private (and slack_read_thread / slack_read_channel only if needed for context). Output ONLY the matches, newest first, at most 8 lines, each formatted as: [#channel or DM] sender (date): text trimmed to ~140 chars. No commentary, no markdown. If nothing matches output exactly: No matches." \
          "${T}slack_search_public_and_private,${T}slack_search_public,${T}slack_read_thread,${T}slack_read_channel,${T}slack_search_channels,${T}slack_search_users,${T}slack_list_user_channels,${T}slack_read_user_profile" ;;
    send|reply|dm)
      target="${args%%:*}"; msg="${args#*:}"; msg="$(printf '%s' "$msg" | sed 's/^ *//')"
      if [ -z "$target" ] || [ -z "$msg" ] || [ "$target" = "$args" ]; then
        echo "usage: slack.sh send \"<#channel|@user|name>: <message>\"" >&2; exit 1
      fi
      if [ "${MARGIE_SLACK_DRY:-0}" = "1" ]; then SENDTOOL="slack_send_message_draft"; VERB="Create a DRAFT (do not send) of"; else SENDTOOL="slack_send_message"; VERB="Send"; fi
      ask "You are Margie's Slack sender, acting as Tom. $VERB exactly ONE Slack message to \"$target\" with this text VERBATIM (no additions, no rewording, no markdown, no signature): <<<$msg>>> Steps: 1) resolve \"$target\" — a #channel, @user, or a person's name — with slack_search_channels / slack_search_users (for a person, send a DM). 2) call $SENDTOOL once. 3) Output ONE line only: Sent to <resolved channel or person>. If the target is ambiguous or not found, send NOTHING and output one line: Could not resolve \"$target\"." \
          "${T}${SENDTOOL},${T}slack_search_channels,${T}slack_search_users,${T}slack_list_user_channels,${T}slack_read_user_profile" ;;
    channels)
      ask "List the Slack channels Tom is a member of, one #name per line, nothing else." "${T}slack_list_user_channels" ;;
    *) echo "usage: slack.sh read [\"<query>\"] | send \"<#channel|@user|name>: <message>\" | channels" >&2; exit 1 ;;
  esac
  exit $?
fi
# ── Backend 1: direct Slack Web API with tokens from config.json ───────────────
case "$TOKEN" in xoxp-*) KIND="user" ;; *) KIND="bot" ;; esac

api() { local method="$1"; shift; curl -sS -H "Authorization: Bearer $TOKEN" "$@" "https://slack.com/api/$method"; }
ok() { jq -e '.ok == true' >/dev/null 2>&1; }

# id → display name cache-ish resolver
uname_of() { api users.info --get --data-urlencode "user=$1" | jq -r '.user.profile.display_name // .user.real_name // .user.name // "?"'; }

cmd="${1:-read}"; shift || true; args="$*"

read_via_search() { # user token only
  local RESP; RESP="$(api search.messages --get --data-urlencode "query=$1" -d "count=15" -d "sort=timestamp")"
  echo "$RESP" | ok || { echo "Slack search failed, dearie: $(echo "$RESP" | jq -r '.error // "unknown"')"; return 1; }
  echo "$RESP" | jq -r '.messages.matches[]? | "• #"+(.channel.name // "?")+" — "+(.username // .user // "?")+": "+((.text // "") | gsub("\n";" "))' | head -20
  echo "$RESP" | jq -e '.messages.matches | length>0' >/dev/null 2>&1 || echo "Nothing matching '$1', dearie."
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
    echo "I'm not in any channels yet, dearie — /invite @margie to the channels you'd like me to watch (DMs to me work already)."
  elif [ "$found" = "0" ]; then
    echo "Nothing recent${query:+ matching '$query'}, dearie."
  fi
}

resolve_target() { # -> channel id to post to
  local t="$1" name id
  # A raw conversation id (channel C…, group/private G…, DM D…) — with or without a leading # — is used as-is.
  case "$t" in
    \#C[A-Z0-9]*|\#G[A-Z0-9]*|\#D[A-Z0-9]*|C[A-Z0-9]*|G[A-Z0-9]*|D[A-Z0-9]*)
      if printf '%s' "${t#\#}" | grep -qE '^[CGD][A-Z0-9]{8,}$'; then echo "${t#\#}"; return; fi ;;
  esac
  case "$t" in
    \#*) name="${t#\#}" ;;
    @*)  name="${t#@}"
         local uid
         case "$name" in
           U[A-Z0-9]*) uid="$name" ;;
           *) uid="$(api users.list -d "limit=1000" | jq -r --arg n "$name" '.members[]? | select((.name==$n) or (.profile.display_name==$n) or (.real_name==$n)) | .id' | head -1)" ;;
         esac
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
  send|reply|dm)
    target="${args%%:*}"; text="${args#*:}"
    target="$(echo "$target" | sed 's/^ *//;s/ *$//')"; text="$(echo "$text" | sed 's/^ *//;s/ *$//')"
    if [ -z "$target" ] || [ -z "$text" ] || [ "$target" = "$args" ]; then
      echo "FORMAT ERROR — nothing sent. The argument must be \"<target>: <message>\" with a colon after the target, e.g. slack.sh send \"@Tom: hello\" or slack.sh send \"#team-engineering: hello\". Retry with a target." >&2
      exit 1
    fi
    cid="$(resolve_target "$target")"
    [ -z "$cid" ] && { echo "Couldn't find '$target' on Slack, dearie (bot must be a member of the channel)." >&2; exit 1; }
    RESP="$(api chat.postMessage --get --data-urlencode "channel=$cid" --data-urlencode "text=$text")"
    if echo "$RESP" | ok; then
      echo "Sent to $target, dearie$([ "$KIND" = bot ] && echo " (as the margie bot)")."
      # cc the owner: a bot's DM with someone else is invisible to Tom, so he gets a copy.
      OWNER_ID="$(jq -r '.slack_owner_id // empty' "$CFG" 2>/dev/null)"
      if [ -n "$OWNER_ID" ] && [ "$cid" != "$(api conversations.list --get --data-urlencode "types=im" -d "limit=1000" | jq -r --arg u "$OWNER_ID" '.channels[]? | select(.user==$u) | .id' | head -1)" ] && [ "$(jq -r '.slack_cc_owner // "true"' "$CFG")" != "false" ]; then
        api chat.postMessage --get --data-urlencode "channel=$OWNER_ID" --data-urlencode "text=📋 Copy of what I sent to *$target*:
$text" >/dev/null 2>&1 || true
      fi
    else echo "Send failed, dearie: $(echo "$RESP" | jq -r '.error // "unknown"')"; exit 1; fi
    ;;
  *)
    echo "usage: slack.sh read [query] | send \"<target>: msg\" | reply \"<target>: msg\"" >&2
    exit 1
    ;;
esac
