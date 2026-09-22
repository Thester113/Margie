#!/bin/bash
# approve.sh — merge a UI MR by reacting ✅ in Slack (Tom, 2026-09-22).
#
# After the UI screenshot lands in Tom's Slack DM, Margie posts one line under it:
# "React ✅ to merge !1227 (PT-1483), ❌ to hold it." Each approval message is tied to ONE
# MR and ONE commit, so a reaction can't land on the wrong MR the way a bare "merge"
# once did (!1199, 2026-09-21).
#
#   approve.sh post <dispatch id> <iid> <sha>   post the prompt, remember it
#   approve.sh poll                             poller (30 s): act on Tom's reactions
#
# Only Tom's own reaction counts (config slack_owner_id). ✅ (white_check_mark,
# heavy_check_mark, ballot_box_with_check) runs dispatch.sh merge — which still enforces
# pipeline green, threads resolved, review approved and the screenshot for THIS commit.
# ❌ (x, no_entry, raised_hand) holds the MR and asks what should change. If the MR moved
# to a new commit since the screenshot, nothing merges; a new screenshot comes instead.
# The reaction IS Tom's confirmation — the brain's OUTWARD read-back doesn't apply,
# because nothing here is composed by a model. Prompts expire after 48 h.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HOME/.margie/config.json"; ST="$HOME/.margie/approvals"; mkdir -p "$ST"
BTOK="$(jq -r '.slack_token // empty' "$CFG" 2>/dev/null)"
OWNER="$(jq -r '.slack_owner_id // empty' "$CFG" 2>/dev/null)"
[ -z "$BTOK" ] || [ -z "$OWNER" ] && exit 0
sapi() { local m="$1"; shift; curl -sS --max-time 10 -H "Authorization: Bearer $BTOK" "$@" "https://slack.com/api/$m" 2>/dev/null; }
BOTUSER="$(sapi auth.test | jq -r '.user_id // empty')"
dm_channel() { sapi conversations.open -d "users=$OWNER" | jq -r '.channel.id // empty'; }
MDIR="$HOME/.margie/dispatch"

case "${1:-}" in
  post)
    D="${2:?dispatch id}"; IID="${3:?iid}"; SHA="${4:?sha}"
    PT="$(jq -r '.pt // empty' "$MDIR/$D/ticket.json" 2>/dev/null)"
    CH="$(dm_channel)"; [ -z "$CH" ] && exit 1
    TS="$(sapi chat.postMessage --get --data-urlencode "channel=$CH" \
      --data-urlencode "text=React ✅ to merge !$IID${PT:+ ($PT)}, or ❌ to hold it." | jq -r '.ts // empty')"
    [ -z "$TS" ] && exit 1
    jq -n --arg d "$D" --arg iid "$IID" --arg sha "$SHA" --arg ch "$CH" --arg ts "$TS" --arg pt "$PT" \
      '{dispatch:$d, iid:$iid, sha:$sha, channel:$ch, ts:$ts, pt:$pt, posted:(now|floor)}' > "$ST/$TS.json"
    echo "posted $TS" ;;
  poll)
    NOW="$(date +%s)"
    for f in "$ST"/*.json; do
      [ -f "$f" ] || continue
      R="$(cat "$f")"; POSTED="$(jq -r .posted <<<"$R")"
      if [ $(( NOW - POSTED )) -gt 172800 ]; then mv "$f" "$f.expired"; continue; fi
      CH="$(jq -r .channel <<<"$R")"; TS="$(jq -r .ts <<<"$R")"; IID="$(jq -r .iid <<<"$R")"
      D="$(jq -r .dispatch <<<"$R")"; SHA="$(jq -r .sha <<<"$R")"; PT="$(jq -r .pt <<<"$R")"
      # Slack sometimes returns raw control characters that stop jq cold — strip them first.
      # Tom's reaction counts on the prompt OR on the screenshot message for this MR: the
      # upload finishes after the prompt is posted, so it lands just below it, and the ✅
      # naturally goes on the picture (2026-09-22, !1246). Only Margie's own messages that
      # name "!$IID" count, and only after the prompt was posted.
      M="$(sapi conversations.history --get --data-urlencode "channel=$CH" --data-urlencode "oldest=$TS" -d inclusive=true -d limit=20 | LC_ALL=C tr '\000-\037' ' ')"
      RX="$(jq -r --arg o "$OWNER" --arg ts "$TS" --arg iid "!$IID" --arg bot "$BOTUSER" \
        '[.messages[]? | select(.ts == $ts or ((.user == $bot or .bot_id != null) and ((.text // "") + ((.files // []) | map(.title // "") | join(" ")) | contains($iid))))
          | .reactions[]? | select(.users | index($o)) | .name] | unique | join(" ")' <<<"$M")"
      [ -z "$RX" ] && continue
      reply() { sapi chat.postMessage --get --data-urlencode "channel=$CH" --data-urlencode "thread_ts=$TS" --data-urlencode "text=$1" >/dev/null; }
      if printf '%s' " $RX " | grep -qE ' (white_check_mark|heavy_check_mark|ballot_box_with_check) '; then
        HEAD="$(jq -r '.sha // empty' "$MDIR/$D/mr-check.json" 2>/dev/null)"
        if [ -n "$HEAD" ] && [ "$HEAD" != "$SHA" ]; then
          reply "!$IID has a new commit since that screenshot, so I didn't merge it — I'll send a fresh screenshot to approve."
          mv "$f" "$f.stale"; echo "!$IID changed since your ✅ — sending a new screenshot instead of merging."; continue
        fi
        OUT="$("$DIR/dispatch.sh" merge "$D" 2>&1 | tail -1)"
        reply "$OUT"; mv "$f" "$f.done"
        echo "You ✅'d !$IID${PT:+ ($PT)} — $OUT"
      elif printf '%s' " $RX " | grep -qE ' (x|no_entry|no_entry_sign|raised_hand) '; then
        printf '%s' "Held by Tom with ❌ on Slack ($(date -u +%FT%TZ)) — waiting for what should change." > "$MDIR/$D/hold-merge"
        reply "Holding !$IID. What should change? Reply here and I'll send it to the session."
        mv "$f" "$f.held"
        echo "You held !$IID${PT:+ ($PT)} with ❌."
      fi
    done ;;
  *) echo "usage: approve.sh post <dispatch> <iid> <sha> | poll" >&2; exit 64 ;;
esac
