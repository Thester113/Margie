#!/bin/bash
# integrations-guard.sh — keep teammates' changes from quietly breaking the integrations flow
# (Tom, 2026-09-25: Howie and JohnnyT change workflows over the weekend; "make sure Margie
# is aware and can preserve our integrations flow").
#
#   integrations-guard.sh auto    poller: an open MR that is NOT Margie's and touches
#                                 guard_paths gets one read-only impact review per commit
#                                 (headless, plan mode, checked against the "What must keep
#                                 working" list in the repo's process notes). OK → one line
#                                 to Tom; CONCERN → Tom's DM plus a note to the MR's author.
#   integrations-guard.sh check <iid> [--for <agent>]   review one MR now; --for sends that
#                                 agent the verdict (OK or CONCERN) as an agent message
#
# Company-agnostic: guard_paths[<repo>], the author map and the default repo are config.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; M="$HOME/.margie"; CFG="$M/config.json"; ST="$M/integrations-guard"
mkdir -p "$ST"
REPO="$("$DIR/resolve-repo.sh" "$(jq -r '.guard_repo // .default_repo // empty' "$CFG")" 2>/dev/null)" || exit 0
RN="$(basename "$REPO")"
PATHS="$(jq -r --arg r "$RN" '.guard_paths[$r][]? // empty' "$CFG")"; [ -n "$PATHS" ] || exit 0
PREFIX="$(jq -r '.branch_prefix // "margie"' "$CFG")"
NOTES="$M/process/$RN.md"

review() { # review <iid> <sha> <author> <title>
  local iid="$1" sha="$2" who="$3" title="$4" task
  # The review runs read-only (no shell), so hand it the MR as files it can Read.
  ( cd "$REPO" && glab mr diff "$iid" --raw > "$ST/$iid.diff" 2>/dev/null; glab mr view "$iid" > "$ST/$iid.view" 2>/dev/null )
  [ -s "$ST/$iid.diff" ] || return 1
  "$DIR/claude-task.sh" start "$REPO" "You are checking merge request !$iid (\"$title\", by $who) in this repository for ONE thing: does it break or weaken the integrations flow that is live in production? The MR's full diff is in $ST/$iid.diff and its description in $ST/$iid.view (Read both); the repository here is main, so Read the surrounding code each hunk touches and calls. The flow that must keep working is the list under 'What must keep working' in this file (read it): $NOTES. Do not edit, commit, comment or push anything.
Answer with a first line that is exactly 'VERDICT: OK' or 'VERDICT: CONCERN', then at most 8 short lines: for a CONCERN, each line names the file, what it changes, which numbered item it endangers and what to keep; for OK, one line on what it touches and why the flow is unaffected. Ground every line in code you read." --plan --tag "guard:!$iid" >/dev/null 2>&1
  # start prints a sentence, not the id; the id is the newest task carrying this tag.
  task="$("$DIR/claude-task.sh" status 2>/dev/null | awk -v t="guard-$iid" '$1 ~ t"$" {print $1; exit}')"
  [ -n "$task" ] && printf '%s\t%s\t%s\t%s\n' "$iid" "$sha" "$task" "$who" > "$ST/$iid.pending"
  echo "$task"
}

case "${1:-auto}" in
  check)
    # check <iid> [--for <agent>]: an agent who asked gets the verdict back either way.
    [ "${3:-}" = "--for" ] && [ -n "${4:-}" ] && printf '%s' "$4" > "$ST/$2.requester"
    MV="$(cd "$REPO" && glab mr view "$2" -F json 2>/dev/null)"
    [ -f "$ST/$2.pending" ] && { echo "already checking !$2"; exit 0; }
    review "$2" "$(printf '%s' "$MV" | jq -r .sha)" "$(printf '%s' "$MV" | jq -r .author.username)" "$(printf '%s' "$MV" | jq -r .title)" ;;
  auto)
    # 1. Finished reviews → report.
    for p in "$ST"/*.pending; do
      [ -f "$p" ] || continue
      IFS=$'\t' read -r iid sha task who < "$p"
      "$DIR/claude-task.sh" status 2>/dev/null | grep -F "$task" | grep -qiE 'done|finished|complete' || continue
      R="$("$DIR/claude-task.sh" result "$task" 2>/dev/null)"
      V="$(printf '%s' "$R" | grep -m1 -oE 'VERDICT: (OK|CONCERN)' | cut -d' ' -f2)"
      # A review that could not read the MR is no verdict: retry once on the next poll.
      if printf '%s' "$R" | grep -qiE "couldn.t read|could not read|can.t run|cannot run|no access"; then
        rm -f "$p"; continue
      fi
      BODY="$(printf '%s' "$R" | sed -n '/VERDICT:/,$p' | sed 1d | head -8)"
      if [ "$V" = CONCERN ]; then
        "$DIR/slack.sh" send "@$(jq -r '.owner_first_name // "Tom"' "$CFG"): Heads-up: $who's MR !$iid touches the integrations flow and may break it:
$BODY" >/dev/null 2>&1
        AG="$(jq -r --arg w "$who" '.guard_authors[$w].agent // empty' "$CFG")"
        [ -n "$AG" ] && "$DIR/agent-messages.sh" send "$AG" "!$iid and the live integrations flow" "Hi! Margie here. I read !$iid against the integrations flow that's live for Homie (FUB/Brevo setup, the Homie run and send, hand-raise write-back). A few things to keep working:
$BODY
Happy to help check a fix. Tom has the same note." >/dev/null 2>&1
      else
        "$DIR/tom-ping.sh" consider "Checked $who's MR !$iid against the integrations flow: OK. $(printf '%s' "$BODY" | head -1)" >/dev/null 2>&1 || true
      fi
      # Someone asked for this check (an agent message): they get the answer, OK or not.
      RQ="$(cat "$ST/$iid.requester" 2>/dev/null)"
      if [ -n "$RQ" ] && ! { [ "$V" = CONCERN ] && [ "$RQ" = "$(jq -r --arg w "$who" '.guard_authors[$w].agent // empty' "$CFG")" ]; }; then
        "$DIR/agent-messages.sh" send "$RQ" "!$iid vs the live integrations flow: ${V:-no verdict}" "Hi! Margie here — you asked about !$iid. I checked it against the integrations flow that's live for Homie (FUB/Brevo setup, the Homie run and send, hand-raise write-back): ${V:-no clear verdict}.
$BODY" >/dev/null 2>&1
      fi
      rm -f "$ST/$iid.requester"
      mv "$p" "$ST/$iid.$sha.done"
    done
    # 2. New commits on teammates' MRs that touch the guarded paths → start a review.
    MRS="$(cd "$REPO" && glab mr list -F json --per-page 50 2>/dev/null | jq -r --arg pfx "$PREFIX/" '.[] | select((.source_branch | startswith($pfx)) | not) | "\(.iid)\t\(.sha)\t\(.author.username)\t\(.title)"')"
    printf '%s\n' "$MRS" | while IFS=$'\t' read -r iid sha who title; do
      [ -n "$iid" ] || continue
      [ -f "$ST/$iid.$sha.done" ] || [ -f "$ST/$iid.pending" ] && continue
      CH="$(cd "$REPO" && glab api "projects/:id/merge_requests/$iid/changes" 2>/dev/null | jq -r '.changes[]? | .new_path, .old_path' | sort -u)"
      HIT=""
      while read -r f; do while read -r pfx; do case "$f" in "$pfx"*) HIT=1;; esac; done <<< "$PATHS"; done <<< "$CH"
      [ -n "$HIT" ] || { touch "$ST/$iid.$sha.done"; continue; }
      review "$iid" "$sha" "$who" "$title" >/dev/null
    done ;;
  *) echo "usage: integrations-guard.sh auto | check <iid>" >&2; exit 64 ;;
esac
