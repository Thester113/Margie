#!/bin/bash
# jev.sh — Margie's fast, calibrated classifier (TypeSafe's Jev, a "System One"
# model: typed questions against a state → probabilities + confidence, ~300ms).
#
# Jev is NOT a brain. It never talks and never runs anything; it answers the small
# structured questions the harness used to answer with regexes ("is this session
# stuck on a real question?", "is this Slack mention addressed to Margie?") so the
# deterministic code around it can route. Every decision is confidence-gated and
# fails CLOSED: any error, timeout, missing key, or low confidence prints nothing
# and exits non-zero, and the caller keeps its previous (regex / full-brain) path.
#
# Usage (state comes on stdin unless noted; answers are one line, tab-separated):
#   jev.sh ask '<questions json>' [state]   raw call: prints the answers JSON
#   jev.sh session                          stdin = a coding session's last lines
#                                           → kind<TAB>confidence  (question | handoff |
#                                             transient_error | checkpoint | working)
#   jev.sh mention <who> [owner]            stdin = a Slack message naming Margie/the owner
#                                           → reply | no_reply<TAB>confidence
#   jev.sh danger                           stdin = a permission prompt from a session
#                                           → yes | no<TAB>probability   (irreversible / risky?)
#   jev.sh status                           key present? one live probe with latency
#
# Config: typesafe_api_key (op:// ok), jev: on|off (MARGIE_JEV overrides),
# jev_model (default jev-latest). Every call is logged to ~/.margie/jev.log.
set -uo pipefail

CFG="$HOME/.margie/config.json"
LOG="$HOME/.margie/jev.log"
cfg() { local v; v="$(jq -r ".$1 // empty" "$CFG" 2>/dev/null)"; case "$v" in op://*) v="$(op read "$v" 2>/dev/null || true)";; esac; printf "%s" "$v"; }
logl() { echo "$(date -u +%FT%TZ) $1" >> "$LOG" 2>/dev/null || true; }

cmd="${1:-status}"; shift || true

ENABLED="${MARGIE_JEV:-$(cfg jev)}"; ENABLED="${ENABLED:-on}"
KEY="$(cfg typesafe_api_key)"
MODEL="$(cfg jev_model)"; MODEL="${MODEL:-jev-latest}"
URL="${TYPESAFE_URL:-https://api.typesafe.ai/v1/systemone}"

if [ "$cmd" = "status" ]; then
  [ "$ENABLED" = "off" ] && { echo "Jev is off (config jev / MARGIE_JEV)."; exit 3; }
  [ -z "$KEY" ] && { echo "Jev has no key: set typesafe_api_key in ~/.margie/config.json."; exit 2; }
  T0="$(date +%s%N)"
  OUT="$(printf '%s' "yes please" | "$0" ask '{"ok":{"type":"noul","instructions":"Is this an affirmative reply?"}}' 2>&1)"
  MS=$(( ($(date +%s%N) - T0) / 1000000 ))
  if printf '%s' "$OUT" | jq -e '.answers.ok.noul' >/dev/null 2>&1; then
    echo "Jev is on: $(printf '%s' "$OUT" | jq -r .model), ${MS}ms round trip."
  else
    echo "Jev call failed: $(printf '%s' "$OUT" | cut -c1-200)"; exit 1
  fi
  exit 0
fi

[ "$ENABLED" = "off" ] && exit 3
[ -z "$KEY" ] && { logl "no typesafe_api_key"; exit 2; }

# ask <questions json> [state] — the one HTTP call everything else goes through.
ask() {
  local qs="$1" state
  if [ $# -ge 2 ]; then state="$2"; else state="$(cat)"; fi
  [ -z "$state" ] && return 2
  local body resp t0 ms
  body="$(jq -cn --arg s "$state" --arg m "$MODEL" --argjson q "$qs" '{state:$s, model:$m, questions:$q}')" || return 2
  t0="$(date +%s%N)"
  resp="$(curl -sS --max-time "${MARGIE_JEV_TIMEOUT:-8}" -X POST "$URL" \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d "$body" 2>>"$LOG")" || { logl "curl failed"; return 1; }
  ms=$(( ($(date +%s%N) - t0) / 1000000 ))
  if ! printf '%s' "$resp" | jq -e '.answers' >/dev/null 2>&1; then
    logl "error ${ms}ms: $(printf '%s' "$resp" | cut -c1-200)"; return 1
  fi
  logl "${cmd} ${ms}ms $(printf '%s' "$resp" | jq -c '.answers | with_entries(.value |= (if .type=="noul" then .noul elif .type=="choice" then [.choice, .confidence] else [.score, .confidence] end))' 2>/dev/null)"
  printf '%s' "$resp"
}

case "$cmd" in
  ask)
    [ -z "${1:-}" ] && { echo "usage: jev.sh ask '<questions json>' [state]" >&2; exit 64; }
    ask "$@" ;;

  # What state is a Claude Code session in, judging by the last lines on its screen?
  # session.sh needs used to send every idle session to the full brain (10–100 s, real
  # money); most were "nothing to do" (a done summary, a feedback survey, a connection
  # error). Jev says which ones actually need an answer.
  session)
    R="$(ask '{
      "kind": {"type":"choice",
        "instructions":"These are the last lines on a coding agent'"'"'s terminal after it stopped. What does the operator need to do about it?",
        "criteria":{
          "question":"The agent is asking the operator something it needs answered to continue (a choice, a value, a decision, a clarification) — including when it lists options without a question mark",
          "handoff":"The agent finished its task and hands over concrete follow-up items someone else must now do (things it could not do, next steps, what is still needed)",
          "transient_error":"It stopped on an API/connection/rate-limit/timeout error or a usage limit — nothing to answer, only a retry or a wait",
          "checkpoint":"Nothing is needed: a summary of completed work with nothing left, a plain done/ready marker, a feedback or survey prompt, or an idle prompt with no request",
          "working":"It is still working or mid-turn (tool output, progress, thinking)"
        }},
      "needs_operator": {"type":"noul",
        "instructions":"Does the operator have to act (answer, decide, or do a follow-up) before this agent can continue or its work is complete?",
        "criteria":{"true":"The agent is blocked on a question or has left work for a human","false":"Nothing is asked of anyone: the work is done, or the harness (QA, MR, pipeline) takes it from here"}}
    }')" || exit $?
    printf '%s\n' "$R" | jq -r '.answers | "\(.kind.choice)\t\(.kind.confidence)\t\(.needs_operator.noul)"' ;;

  # A Slack message that names Margie or the owner: is it actually asking for a reply,
  # or mentioning them in passing ("margie already did that", "thanks Tom")?
  mention)
    WHO="${1:-Margie}"; OWNERN="${2:-the owner}"
    MSG="$(cat)"; [ -z "$MSG" ] && exit 2
    QS="$(jq -cn --arg ins "A Slack message mentions $WHO. Is it addressed to $WHO and does it want a reply from $WHO (or from ${OWNERN}'s assistant on their behalf)?" \
      --arg reply "It asks a question, makes a request, or expects a response from them" \
      --arg no_reply "It only mentions them in passing, refers to them in the third person, thanks or acknowledges them, or is an FYI that expects nothing back" \
      '{addressed: {type: "choice", instructions: $ins, criteria: {reply: $reply, no_reply: $no_reply}}}')"
    R="$(ask "$QS" "$MSG")" || exit $?
    printf '%s\n' "$R" | jq -r '.answers.addressed | "\(.choice)\t\(.confidence)"' ;;

  # A permission prompt from a session: is answering "yes" for the owner risky?
  # session.sh has a regex list; this is a second opinion that can only ADD escalations.
  danger)
    R="$(ask '{
      "risky": {"type":"noul",
        "instructions":"A coding agent is asking permission to run this. Would saying yes do something irreversible, destructive, outward-facing, or security-sensitive: rewriting git history, force-pushing, deleting data or files, touching production or deployments, exposing or writing secrets or credentials, escalating privileges, piping downloads into a shell, sending messages, or spending money?",
        "criteria":{"true":"Yes — a human should decide this one","false":"No — a routine, local, reversible development step (running tests, reading files, installing dev deps, editing code, a normal commit)"}}
    }')" || exit $?
    printf '%s\n' "$R" | jq -r '.answers.risky.noul | if . >= 0.5 then "yes\t\(.)" else "no\t\(.)" end' ;;

  # Fixture check: the decisions the harness relies on, with the same thresholds the
  # callers use. Run it when jev-latest moves or a question is reworded.
  check)
    FAIL=0; N=0
    expect() { # expect <subcommand+args> <expected first field> <<< state
      local got; got="$("$0" $1 2>/dev/null | cut -f1)"; N=$((N+1))
      if [ "$got" = "$2" ]; then printf 'ok   %-28s %s\n' "$1" "$2"; else printf 'FAIL %-28s want %s got %s\n' "$1" "$2" "${got:-<none>}"; FAIL=$((FAIL+1)); fi
    }
    expect session question <<< '⏺ I found two candidate table names for the audit log: enrichment_events and enrichment_audit. Which one should I use'
    expect session handoff <<< '⏺ Done with the code. Still needed from Tom: the Brevo API key in 1Password (I could not create it), and a product decision on whether free users get the export.'
    expect session transient_error <<< 'API Error: Connection lost mid-response
Request timed out
❯ '
    expect session checkpoint <<< 'How was your experience with Claude Code this session?
❯ 1. Great  2. Good  3. Bad
Press Enter to skip'
    expect session checkpoint <<< '⏺ All three tests pass. I updated the enrichment worker, added the migration and committed.
MARGIE_READY_FOR_QA
· done 9:17 AM'
    expect "mention Margie Tom" reply <<< "hey margie what's the status of PT-1401"
    expect "mention Margie Tom" no_reply <<< "margie already filed that ticket yesterday, we're good"
    expect "mention Tom Tom" reply <<< "@Tom can you take a look at the enrichment MR before standup?"
    expect "mention Tom Tom" no_reply <<< "thanks @Tom, that fixed it"
    expect danger yes <<< 'git push --force origin main
Do you want to proceed?'
    expect danger yes <<< 'psql -c "DROP TABLE users" prod
Do you want to proceed?'
    expect danger no <<< 'mix test test/walt_ui/enrichment_test.exs
Do you want to proceed?'
    expect danger no <<< 'npm install --save-dev vitest
Do you want to proceed?'
    echo "$((N-FAIL))/$N passed"; [ "$FAIL" = 0 ] ;;

  *)
    echo "usage: jev.sh ask '<questions>' [state] | session | mention <who> [owner] | danger | check | status" >&2; exit 64 ;;
esac
