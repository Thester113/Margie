#!/bin/bash
# telnyx.sh — the little Telnyx toolkit for the group-MMS spike (and later ops).
# API key in ~/.margie/config.json: telnyx_api_key (a v2 "KEY…" API key).
#
#   telnyx.sh numbers                         numbers this account owns (+ messaging profile)
#   telnyx.sh search <area code> [n]          available MMS-capable long codes (US)
#   telnyx.sh buy <+1e164>                    order a number                          [held: spends money]
#   telnyx.sh profile [name]                  ensure a messaging profile exists; print its id
#   telnyx.sh assign <+1e164> [profile id]    put a number on the messaging profile
#   telnyx.sh send-group "<+1a,+1b>" "<text>" [--from +1e164]   group MMS to every recipient  [held]
#   telnyx.sh send "<+1to>" "<text>" [--from +1e164]           single SMS                    [held]
#   telnyx.sh message <id>                    delivery status of a sent message
#   telnyx.sh spike "<agent +1>,<client +1>"  the whole T1 check: send the group reply and print what to look for
set -uo pipefail
CFG="$HOME/.margie/config.json"
cfg() { jq -r ".$1 // empty" "$CFG" 2>/dev/null; }
desc() { if [ "${MARGIE_DESCRIBE:-0}" = "1" ]; then echo "$*"; exit 0; fi; }
KEY="$(cfg telnyx_api_key)"
[ -z "$KEY" ] && { echo "No Telnyx key yet, dearie — add telnyx_api_key to ~/.margie/config.json (Telnyx portal → API Keys)." >&2; exit 1; }
api() { local m="$1" p="$2"; shift 2; curl -sSg -X "$m" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" "https://api.telnyx.com/v2$p" "$@"; }
err() { printf '%s' "$1" | jq -e '.errors' >/dev/null 2>&1 && { echo "Telnyx said: $(printf '%s' "$1" | jq -r '.errors[0].detail // .errors[0].title')" >&2; return 0; }; return 1; }
FROM="$(cfg telnyx_number)"
cmd="${1:-numbers}"; shift || true
ARGS=(); while [ $# -gt 0 ]; do case "$1" in --from) FROM="${2:-}"; shift 2 ;; *) ARGS+=("$1"); shift ;; esac; done; set -- ${ARGS[@]+"${ARGS[@]}"}
case "$cmd" in
  numbers)
    R="$(api GET "/phone_numbers?page[size]=50")"; err "$R" && exit 1
    printf '%s' "$R" | jq -r '.data[]? | "\(.phone_number)  \(.status)  profile=\(.messaging_profile_id // "-")"'; [ "$(printf '%s' "$R" | jq '.data|length')" = 0 ] && echo "No numbers yet, dearie — telnyx.sh search <area code>, then buy." ;;
  search)
    AC="${1:?area code}"; N="${2:-5}"
    R="$(api GET "/available_phone_numbers?filter[country_code]=US&filter[national_destination_code]=$AC&filter[features][]=mms&filter[features][]=sms&filter[phone_number_type]=local&filter[limit]=$N")"; err "$R" && exit 1
    printf '%s' "$R" | jq -r '.data[]? | "\(.phone_number)  \(.cost_information.monthly_cost // "?") \(.cost_information.currency // "")/mo  features: \([.features[].name]|join(","))"' ;;
  buy)
    NUM="${1:?+1 number}"; desc "would order Telnyx number $NUM (about \$1/mo plus messaging)"
    R="$(api POST /number_orders -d "$(jq -nc --arg n "$NUM" '{phone_numbers:[{phone_number:$n}]}')")"; err "$R" && exit 1
    echo "Ordered $NUM — status $(printf '%s' "$R" | jq -r '.data.status'). Saving it as telnyx_number."
    jq --arg n "$NUM" '.telnyx_number = $n' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG" && chmod 600 "$CFG" ;;
  profile)
    NAME="${1:-Margie spike}"
    R="$(api GET "/messaging_profiles?page[size]=50")"; err "$R" && exit 1
    ID="$(printf '%s' "$R" | jq -r --arg n "$NAME" '.data[]? | select(.name==$n) | .id' | head -1)"
    if [ -z "$ID" ]; then
      C="$(api POST /messaging_profiles -d "$(jq -nc --arg n "$NAME" '{name:$n, webhook_api_version:"2"}')")"; err "$C" && exit 1
      ID="$(printf '%s' "$C" | jq -r .data.id)"; echo "Created messaging profile \"$NAME\"."
    fi
    echo "$ID"; jq --arg p "$ID" '.telnyx_profile_id = $p' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG" && chmod 600 "$CFG" ;;
  assign)
    NUM="${1:?+1 number}"; PID="${2:-$(cfg telnyx_profile_id)}"; [ -z "$PID" ] && PID="$("$0" profile | tail -1)"
    R="$(api PATCH "/phone_numbers/$NUM/messaging" -d "$(jq -nc --arg p "$PID" '{messaging_profile_id:$p}')")"; err "$R" && exit 1
    echo "$NUM is on messaging profile $PID." ;;
  send-group)
    TO="${1:?comma-separated +1 numbers}"; TEXT="${2:?text}"; [ -z "$FROM" ] && { echo "Which number do I send from, dearie? --from +1… or telnyx_number in config." >&2; exit 1; }
    desc "would send a Telnyx GROUP MMS from $FROM to $TO: \"$TEXT\""
    R="$(api POST /messages/group_mms -d "$(jq -nc --arg f "$FROM" --arg t "$TEXT" --argjson to "$(printf '%s' "$TO" | jq -Rc 'split(",") | map(gsub(" ";""))')" '{from:$f, to:$to, text:$t}')")"; err "$R" && exit 1
    MID="$(printf '%s' "$R" | jq -r .data.id)"; GID="$(printf '%s' "$R" | jq -r '.data.group_message_id // "-"')"
    echo "Sent group MMS $MID from $FROM to $TO — group_message_id $GID. Check delivery: telnyx.sh message $MID" ;;
  send)
    TO="${1:?+1 number}"; TEXT="${2:?text}"; [ -z "$FROM" ] && { echo "Which number do I send from, dearie? --from +1… or telnyx_number in config." >&2; exit 1; }
    desc "would send a Telnyx SMS from $FROM to $TO: \"$TEXT\""
    R="$(api POST /messages -d "$(jq -nc --arg f "$FROM" --arg to "$TO" --arg t "$TEXT" '{from:$f, to:$to, text:$t}')")"; err "$R" && exit 1
    echo "Sent $(printf '%s' "$R" | jq -r .data.id) to $TO." ;;
  message)
    R="$(api GET "/messages/${1:?id}")"; err "$R" && exit 1
    printf '%s' "$R" | jq -r '.data | .id + "  type=" + .type + "  " + (.to | map(.phone_number + "=" + .status) | join("  ")) + ((.errors // []) | if length>0 then "\n  FAILED: " + (map("[" + .code + "] " + .detail + (if .meta.url then " (" + .meta.url + ")" else "" end)) | join("; ")) else "" end)' ;;
  ready)
    R="$(api GET "/phone_numbers?page[size]=50")"; N="$(printf '%s' "$R" | jq -r '.data | length')"
    B="$(api GET "/10dlc/brand?page=1&recordsPerPage=1" | jq -r '(.records // .data // []) | length')"
    C="$(api GET "/10dlc/campaign?page=1&recordsPerPage=1" | jq -r '(.records // .data // []) | length')"
    echo "Numbers: $N. 10DLC brand: $([ "${B:-0}" -gt 0 ] && echo yes || echo NO). 10DLC campaign: $([ "${C:-0}" -gt 0 ] && echo yes || echo NO)."
    if [ "${B:-0}" -gt 0 ] && [ "${C:-0}" -gt 0 ]; then echo "A2P to US: registered — sends should deliver."
    else echo "A2P to US: NOT deliverable yet — US carriers reject unregistered A2P long-code traffic (error 40010). Register a 10DLC brand + campaign (company legal name/EIN/address + a small per-campaign fee) before any real send. This is on Tom."; fi ;;
  spike)
    TO="${1:?<agent +1>,<client +1>}"
    [ -z "$FROM" ] && { echo "Buy and assign a number first, dearie (telnyx.sh search/buy/assign)." >&2; exit 1; }
    echo "T1 spike — steps:"
    CLIENT="${TO#*,}"
    echo "1. From the AGENT phone, start a NEW group text to $CLIENT AND $FROM together; send 'hi both'."
    echo "2. Then I reply from $FROM to both as a group MMS (below)."
    echo "3. On BOTH phones: did my reply land inside the thread from step 1 (pass) or as a new conversation from $FROM (fail)?"
    "$0" send-group "$TO" "Hi both — this is Amby's test reply. If you can read this inside the thread you started, the group MMS check passes." ;;
  campaign)
    CF="$HOME/.margie/telnyx-campaign.json"
    [ -s "$CF" ] || { echo "No filled campaign yet, dearie — $CF is missing." >&2; exit 1; }
    sub="${1:-fill}"
    case "$sub" in
      fill|show)
        echo "Filled 10DLC campaign (NOT submitted — no fee charged):"
        jq -r 'to_entries[] | "  \(.key): \(.value|tostring|.[0:120])"' "$CF"
        echo; echo "Review it, then Tom submits (per-campaign fee + TCR review): telnyx.sh campaign submit" ;;
      submit|create)
        desc "would SUBMIT the 10DLC campaign to Telnyx/TCR (brand $(jq -r .brandId "$CF"), usecase $(jq -r .usecase "$CF")) — this incurs a per-campaign fee and is Tom's to authorize"
        R="$(api POST /10dlc/campaignBuilder -d "@$CF")"; err "$R" && exit 1
        CID="$(printf '%s' "$R" | jq -r '.campaignId // .id // .tcrCampaignId // empty')"
        echo "Submitted 10DLC campaign${CID:+ $CID} — status $(printf '%s' "$R" | jq -r '.status // "pending"'). Next: assign $FROM to it, then A2P sends deliver." ;;
      *) echo "usage: telnyx.sh campaign fill | submit" >&2; exit 1 ;;
    esac ;;
  *) echo "usage: telnyx.sh numbers | search <area> [n] | buy <+1> | profile [name] | assign <+1> [profile] | send-group \"<+1,+1>\" \"<text>\" [--from +1] | send <+1> \"<text>\" | message <id> | ready | campaign fill|submit | spike \"<agent>,<client>\"" >&2; exit 1 ;;
esac
