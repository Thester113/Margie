#!/bin/bash
# standup.sh — Margie drafts and posts the owner's daily standup from evidence.
#
#   standup.sh evidence [--since <date>]   what she found (commits, MRs, tickets, dispatches)
#   standup.sh draft    [--since <date>]   compose the three-question standup (Claude, no tools)
#   standup.sh show                        today's draft
#   standup.sh edit "<instruction>"        revise today's draft ("drop the second bullet", "add: …")
#   standup.sh post     [--draft-only]     [held] post today's standup to the standup channel as @Margie
#   standup.sh auto                        poller: on weekdays at/after standup_time, draft once and
#                                          DM the owner (mode draft) or post (mode post). Silent otherwise.
#
# Config (~/.margie/config.json):
#   standup_channel   "#standup" (name or id)     standup_time "08:45" (local, weekdays)
#   standup_mode      draft | post | off (default draft)
#   owner_first_name, slack_owner_id, repos_dir, org, forge — as elsewhere
# Evidence is gathered from: git log --author=<owner email> in every repo under
# repos_dir (+ this checkout), the forge (MRs by @me updated since), Margie's
# dispatch/ticket state, and acked agent messages. Composition is a headless
# Claude call with every tool stripped; the draft is shown before posting.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CFG="$HOME/.margie/config.json"
cfg() { jq -r ".$1 // empty" "$CFG" 2>/dev/null; }
desc() { if [ "${MARGIE_DESCRIBE:-0}" = "1" ]; then echo "$*"; exit 0; fi; }
SDIR="$HOME/.margie/standup"; mkdir -p "$SDIR"
TODAY="$(date +%F)"; DRAFT="$SDIR/$TODAY.md"; POSTED="$SDIR/$TODAY.posted"
OWNER="$(cfg owner_first_name)"; OWNER="${OWNER:-Tom}"
OWNER_ID="$(cfg slack_owner_id)"
CHAN="$(cfg standup_channel)"; CHAN="${CHAN:-#standup}"
MODE="$(cfg standup_mode)"; MODE="${MODE:-draft}"
STIME="$(cfg standup_time)"; STIME="${STIME:-08:45}"
REPOS_DIR="$(cfg repos_dir | sed "s|^~|$HOME|")"; REPOS_DIR="${REPOS_DIR:-$HOME/repos}"
EMAIL="$(git config --global user.email 2>/dev/null)"
CLAUDE_BIN="${MARGIE_CLAUDE_BIN:-$(command -v claude || echo "$HOME/.local/bin/claude")}"
BTOK="$(cfg slack_token)"

# Since when? Last posted standup, else previous weekday.
since_default() {
  local last; last="$(ls "$SDIR"/*.posted 2>/dev/null | sort | tail -1 | xargs -n1 basename 2>/dev/null | sed 's/\.posted$//')"
  if [ -n "$last" ] && [ "$last" != "$TODAY" ]; then echo "$last"; return; fi
  case "$(date +%u)" in 1) date -v-3d +%F ;; *) date -v-1d +%F ;; esac
}

cmd="${1:-draft}"; shift || true
SINCE=""; DRAFT_ONLY=0; REST=()
while [ $# -gt 0 ]; do case "$1" in --since) SINCE="${2:-}"; shift 2 ;; --draft-only) DRAFT_ONLY=1; shift ;; *) REST+=("$1"); shift ;; esac; done
set -- ${REST[@]+"${REST[@]}"}
SINCE="${SINCE:-$(since_default)}"

evidence() {
  echo "## Commits by $OWNER since $SINCE"
  for r in "$HOME/margie/Margie" "$REPOS_DIR"/*/; do
    [ -d "$r/.git" ] || continue
    local n; n="$(git -C "$r" log --all --author="$EMAIL" --since="$SINCE 00:00" --oneline 2>/dev/null | wc -l | tr -d ' ')"
    [ "$n" = 0 ] && continue
    echo "### $(basename "$r") ($n)"
    git -C "$r" log --all --author="$EMAIL" --since="$SINCE 00:00" --format='- %s (%ad)' --date=short 2>/dev/null | head -25
  done
  echo; echo "## Merge requests by $OWNER updated since $SINCE"
  if [ "$(cfg forge)" = "gitlab" ]; then
    local ORG; ORG="$(cfg org)"
    local ME; ME="$(glab api user 2>/dev/null | jq -r .username)"
    glab api "groups/$(jq -rn --arg s "$ORG" '$s|@uri')/merge_requests?author_username=$ME&updated_after=${SINCE}T00:00:00Z&per_page=20&scope=all" 2>/dev/null \
      | jq -r '.[]? | "- !\(.iid) \(.title) — \(.state)\(if .merged_at then " (merged " + .merged_at[0:10] + ")" else "" end) — \(.references.full | split("!")[0])"' || echo "(forge unavailable)"
  else
    gh search prs --author=@me --updated=">=$SINCE" -L 20 --json number,title,state,repository --jq '.[] | "- #\(.number) \(.title) — \(.state) — \(.repository.nameWithOwner)"' 2>/dev/null || echo "(forge unavailable)"
  fi
  echo; echo "## Margie dispatches (specs / tickets in flight)"
  "$DIR/dispatch.sh" status 2>/dev/null
  echo; echo "## Agent messages handled since $SINCE"
  grep -h "CANCELLED\|Acknowledged\|FASTPATH" ~/.margie/brain.log 2>/dev/null | awk -v s="$SINCE" '$1 >= s' | grep -c . | sed 's/^/- acked\/handled: /'
  echo; echo "## Live state now"
  echo "- agent messages: $("$DIR/agent-messages.sh" check 2>/dev/null | grep . || echo "inbox empty")"
  echo "- background tasks: $("$DIR/claude-task.sh" status 2>/dev/null | grep -c RUNNING) running"
}

compose() {
  local EV; EV="$(evidence)"
  local P="You are Margie, ${OWNER}'s assistant, drafting HIS daily standup for the team's #standup channel. Below is the evidence of what he did (git commits, merge requests, tickets, Margie's dispatch pipeline). Write it in the channel's exact three-question format, first person as ${OWNER}:

*What have you done since yesterday?*
• …
*What will you do today?*
• …
*Have anything for after standup?*
• …

Rules: bullets only, each ≤ 14 words, plain Slack formatting (asterisks for the three headers, • bullets). Group related commits into one bullet; mention MR numbers (!123) and ticket ids (PT-###) when present. 'Today' should be inferred from in-flight dispatches/tickets/open MRs; if unknown, write 'continue on <the in-flight item>'. Put blockers or things needing a decision under the third header; if none, write '• Nothing'. Do not invent work that isn't in the evidence. Output ONLY the standup text.

EVIDENCE:
$EV"
  local out
  out="$(cd "$HOME" && "$CLAUDE_BIN" -p "$P" --model "${MARGIE_STANDUP_MODEL:-sonnet}" --output-format json \
        --disallowedTools "Bash,Edit,Write,NotebookEdit,Agent,WebFetch,WebSearch,Read,Glob,Grep" 2>/dev/null | jq -r '.result // empty')"
  [ -n "$out" ] || { echo "Couldn't compose the standup, sir (Claude returned nothing)." >&2; return 1; }
  printf '%s\n' "$out" > "$DRAFT"
  cat "$DRAFT"
}

sapi() { local m="$1"; shift; curl -sS --max-time 10 -H "Authorization: Bearer $BTOK" "$@" "https://slack.com/api/$m"; }
channel_id() {
  case "$CHAN" in C*|G*) printf '%s' "$CHAN"; return ;; esac
  sapi conversations.list --get --data-urlencode "types=public_channel,private_channel" -d "limit=1000" | jq -r --arg n "${CHAN#\#}" '.channels[]? | select(.name==$n) | .id' | head -1
}
dm_owner() { [ -n "$OWNER_ID" ] && sapi chat.postMessage --get --data-urlencode "channel=$OWNER_ID" --data-urlencode "text=$1" >/dev/null 2>&1; }

case "$cmd" in
  evidence) evidence ;;
  draft) compose ;;
  show) [ -s "$DRAFT" ] && cat "$DRAFT" || echo "No standup drafted yet today, sir — say 'draft my standup'." ;;
  edit)
    INSTR="$*"; [ -z "$INSTR" ] && { echo "usage: standup.sh edit \"<what to change>\"" >&2; exit 1; }
    [ -s "$DRAFT" ] || compose >/dev/null || exit 1
    P="Rewrite this Slack standup exactly as instructed and output ONLY the new standup text (same three bold headers, • bullets, ≤ 14 words each): INSTRUCTION: $INSTR

CURRENT:
$(cat "$DRAFT")"
    out="$(cd "$HOME" && "$CLAUDE_BIN" -p "$P" --model "${MARGIE_STANDUP_MODEL:-sonnet}" --output-format json \
          --disallowedTools "Bash,Edit,Write,NotebookEdit,Agent,WebFetch,WebSearch,Read,Glob,Grep" 2>/dev/null | jq -r '.result // empty')"
    [ -n "$out" ] || { echo "Couldn't revise the draft, sir." >&2; exit 1; }
    printf '%s\n' "$out" > "$DRAFT"; cat "$DRAFT" ;;
  post)
    [ -s "$DRAFT" ] || compose >/dev/null || exit 1
    [ -f "$POSTED" ] && { echo "Today's standup is already posted, sir: $(cat "$POSTED")"; exit 0; }
    desc "would post ${OWNER}'s standup for $TODAY to $CHAN as @Margie ($(grep -c '^•' "$DRAFT") bullets: $(sed -n '2p' "$DRAFT" | cut -c1-70)…)"
    CID="$(channel_id)"; [ -z "$CID" ] && { echo "Couldn't find channel $CHAN, sir." >&2; exit 1; }
    TEXT="*${OWNER}'s standup* (via Margie)
$(cat "$DRAFT")"
    R="$(sapi chat.postMessage --get --data-urlencode "channel=$CID" --data-urlencode "text=$TEXT")"
    printf '%s' "$R" | jq -e '.ok==true' >/dev/null || { echo "Slack refused the post, sir: $(printf '%s' "$R" | jq -r '.error // "?"')" >&2; exit 1; }
    LINK="$(sapi chat.getPermalink --get --data-urlencode "channel=$CID" --data-urlencode "message_ts=$(printf '%s' "$R" | jq -r .ts)" | jq -r '.permalink // empty')"
    printf '%s' "${LINK:-posted}" > "$POSTED"
    echo "Posted ${OWNER}'s standup to $CHAN, sir.${LINK:+ $LINK}" ;;
  auto)
    [ "$MODE" = "off" ] && exit 0
    case "$(date +%u)" in 6|7) exit 0 ;; esac
    [ "$(date +%H:%M)" \< "$STIME" ] && exit 0
    [ -f "$POSTED" ] && exit 0
    [ -f "$SDIR/$TODAY.notified" ] && exit 0
    compose >/dev/null 2>&1 || exit 0
    : > "$SDIR/$TODAY.notified"
    if [ "$MODE" = "post" ]; then
      OUT="$("$0" post)"; echo "Your standup is posted in $CHAN, sir."
      dm_owner "Standup posted to $CHAN: $(cat "$POSTED")"
    else
      dm_owner "Your standup draft for today — say \"post my standup\" (or \"change …\") to Margie:
$(cat "$DRAFT")"
      echo "Your standup draft is ready, sir — I've DM'd it to you; say \"post my standup\" when it's right."
    fi ;;
  *) echo "usage: standup.sh evidence|draft [--since d] | show | post | auto" >&2; exit 1 ;;
esac
