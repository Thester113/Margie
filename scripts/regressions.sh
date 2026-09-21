#!/bin/bash
# regressions.sh — proactive regression hunt in Margie's OWNED code (Tom's rule 2026-09-14:
# "in her area of ownership have her look for regressions and fix them, using the same review
# standards we do now"). Ownership = everything her commits have touched (Tom's choice).
#
# DETECTION uses the repo's reviewer charters (code-reviewer + adr-reviewer) — the SAME
# standards as MR review — with the evidence rule that stops hallucinated findings.
# FIXES are routed through dispatch.sh (spec -> go -> QA -> charter review -> UI/backend gate),
# so every fix meets the same review standards and honors the merge gate (backend auto-merges;
# UI/UX holds for Tom). Margie never commits a fix directly — the DENY guards forbid that.
#
#   regressions.sh owned [repo] [--since <date>]   list the owned files
#   regressions.sh scan  [repo] [--since <date>]   headless charter regression review -> JSON (async)
#   regressions.sh show                            last scan's findings
#   regressions.sh hunt  [repo]                    dispatch a pipeline fix for the top un-dispatched
#                                                  confirmed/likely regression (one per call), notify Tom
#   regressions.sh auto                            poller: per config, kick a daily scan and (mode=fix)
#                                                  hunt one fix once a scan finishes. Silent otherwise.
#
# Config: regression_scan   off | scan | fix   (default off; scan = find+report, fix = also dispatch)
#         regression_scan_time "09:30"   regression_since_days 14   regression_repo (default default_repo)
#         review_agents, review_effort, qa_model, dispatch_budget_usd — reused from dispatch.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HOME/.margie/config.json"
cfg()  { jq -r ".$1 // empty" "$CFG" 2>/dev/null; }
cfgd() { local v; v="$(cfg "$1")"; [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"; }
OWNER="$(cfgd owner_first_name Tom)"
EMAIL="$(cfgd owner_email "$(cfg gmail_address)")"; [ -z "$EMAIL" ] && EMAIL="$(git config user.email 2>/dev/null)"
STATE="$HOME/.margie/regressions"; mkdir -p "$STATE"
ANN="$HOME/.margie/announce"; announce() { mkdir -p "$ANN"; printf '%s\n' "$1" > "$ANN/reg-$(date +%s%N).txt"; }

cmd="${1:-scan}"; shift 2>/dev/null || true
REPO_ARG=""; SINCE=""
while [ $# -gt 0 ]; do case "$1" in --since) SINCE="${2:-}"; shift 2;; *) [ -z "$REPO_ARG" ] && REPO_ARG="$1"; shift;; esac; done
[ -z "$REPO_ARG" ] && REPO_ARG="$(cfgd regression_repo "$(cfgd default_repo walt_ui)")"
[ -z "$SINCE" ] && SINCE="$(date -v-"$(cfgd regression_since_days 14)"d +%F 2>/dev/null || date +%F)"
REPO="$("$DIR/resolve-repo.sh" "$REPO_ARG" 2>/dev/null)"; [ -z "$REPO" ] && { echo "Can't resolve repo '$REPO_ARG', dearie." >&2; exit 1; }
SUBDIR="$(jq -r --arg r "$(basename "$REPO")" '.repo_subdirs[$r] // empty' "$CFG" 2>/dev/null)"
WORKDIR="$REPO${SUBDIR:+/$SUBDIR}"

owned_paths() {
  # Everything Margie has touched: non-test lib files her commits (author = owner email)
  # changed since $SINCE and that still exist on disk. Broad, per Tom's ownership choice.
  git -C "$REPO" log --all --author="$EMAIL" --since="$SINCE 00:00" --name-only --pretty=format: 2>/dev/null \
    | grep -E '/lib/' | grep -vE '_test\.exs$' | sort -u \
    | while IFS= read -r f; do [ -n "$f" ] && [ -f "$REPO/$f" ] && echo "$f"; done
}

start_scan() {
  local OWNED P RAGENTS AG AGF OUT M; local -a MODEL_OPT=()
  OWNED="$(owned_paths | head -80)"
  [ -z "$OWNED" ] && { echo "No owned files found since $SINCE, dearie."; return 1; }
  P="$(cat "$DIR/prompts/regression-scan.md")"
  P="${P//'{{OWNER}}'/$OWNER}"; P="${P//'{{SINCE}}'/$SINCE}"; P="${P//'{{OWNED}}'/$OWNED}"
  RAGENTS=""
  for AG in $(jq -r '.review_agents[]? // empty' "$CFG" 2>/dev/null); do
    AGF="$REPO/.claude/agents/$AG.md"; [ -f "$AGF" ] || continue
    RAGENTS="$RAGENTS

===== reviewer charter: $AG =====
$(awk 'c>=2; /^---$/{c++}' "$AGF")"
  done
  [ -n "$RAGENTS" ] && RAGENTS="APPLY THESE REPO REVIEWER CHARTERS (the same standards as MR review):$RAGENTS
"
  P="${P//'{{REVIEW_AGENTS}}'/$RAGENTS}"
  OUT="$STATE/scan-$(date +%s).json"
  M="$(cfg qa_model)"; [ -n "$M" ] && MODEL_OPT=(--model "$M")
  if "$DIR/claude-task.sh" start "$WORKDIR" "$P" --deny "Edit,Write,NotebookEdit" --no-subagents \
       --schema "$DIR/schemas/regression.schema.json" --effort "$(cfgd review_effort high)" \
       --budget "$(cfgd dispatch_budget_usd 4)" --tag "regscan" --out "$OUT" ${MODEL_OPT[@]+"${MODEL_OPT[@]}"} >/dev/null 2>&1; then
    echo "$OUT" > "$STATE/last-scan-path"; date +%F > "$STATE/last-scan-day"
    return 0
  fi
  return 1
}

case "$cmd" in
  owned) owned_paths ;;

  scan)
    if start_scan; then echo "Regression scan running over $OWNER's owned code in $(basename "$REPO")${SUBDIR:+/$SUBDIR}, dearie — results in a few minutes (regressions.sh show)."
    else echo "Couldn't start the scan, dearie."; fi ;;

  show)
    P="$(cat "$STATE/last-scan-path" 2>/dev/null)"
    [ -s "$P" ] && jq -e '.regressions' "$P" >/dev/null 2>&1 || { echo "No finished scan yet, dearie — run regressions.sh scan and give it a few minutes."; exit 0; }
    jq -r 'if (.regressions|length)>0 then (.regressions[] | "[\(.severity)/\(.confidence)] \(.file)\(if .line then ":"+(.line|tostring) else "" end) — \(.summary)") else "No regressions found in the owned code, dearie." end' "$P" ;;

  hunt)
    P="$(cat "$STATE/last-scan-path" 2>/dev/null)"
    [ -s "$P" ] && jq -e '.regressions' "$P" >/dev/null 2>&1 || { echo "Run a scan first and let it finish, dearie (regressions.sh scan)." >&2; exit 1; }
    # one regression per call (dispatch.sh already serializes: one planner per repo) — highest
    # severity first, confirmed/likely only, skip any already dispatched.
    reg="$(jq -c '[.regressions[] | select(.confidence!="uncertain")]
                  | sort_by(if .severity=="blocker" then 0 elif .severity=="major" then 1 else 2 end)
                  | .[]' "$P" 2>/dev/null | while IFS= read -r r; do
             id="$(printf '%s' "$r" | jq -r .id)"; [ -f "$STATE/dispatched-$id" ] || { printf '%s' "$r"; break; }
           done)"
    [ -z "$reg" ] && { echo "No new confirmed/likely regressions to fix, dearie."; exit 0; }
    id="$(printf '%s' "$reg" | jq -r .id)"; sev="$(printf '%s' "$reg" | jq -r .severity)"
    file="$(printf '%s' "$reg" | jq -r .file)"; sum="$(printf '%s' "$reg" | jq -r .summary)"
    repro="$(printf '%s' "$reg" | jq -r .repro)"; fix="$(printf '%s' "$reg" | jq -r .fix)"
    ASK="Regression fix ($sev) in $file: $sum Reproduce first: $repro Then fix: $fix. Add or keep a test that would have caught this regression. Scope the change to THIS regression only — no unrelated refactors."
    if "$DIR/dispatch.sh" spec "$REPO_ARG" "$ASK" ${SUBDIR:+--subdir "$SUBDIR"} >/dev/null 2>&1; then
      touch "$STATE/dispatched-$id"
      MSG="Found a $sev regression in $file and started a fix, dearie: $sum It'll go through QA + charter review + the merge gate like any change (backend auto-merges; UI holds for you). Review the spec with dispatch.sh show, then say go."
      echo "$MSG"; announce "$MSG"
    else echo "Couldn't dispatch the fix for $id, dearie (a planner may already be running in $REPO_ARG)."; fi ;;

  auto)
    # Honour the global pause (dispatch.sh pause): a paused Margie starts no
    # scan, so nothing new gets dispatched while Tom has her stopped.
    [ -f "$HOME/.margie/paused" ] && exit 0
    MODE="$(cfgd regression_scan off)"; [ "$MODE" = off ] && exit 0
    HH="$(date +%H%M)"; WANT="$(cfgd regression_scan_time 0930 | tr -d ':')"
    DOW="$(date +%u)"  # 1..7
    LAST="$(cat "$STATE/last-scan-day" 2>/dev/null)"
    # kick one scan per weekday at/after the scheduled time
    if [ "$DOW" -le 5 ] && [ "$HH" -ge "$WANT" ] && [ "$LAST" != "$(date +%F)" ]; then
      start_scan >/dev/null 2>&1 && announce "Starting my daily regression sweep of the owned code, dearie."
      exit 0
    fi
    # mode=fix: once a scan has finished and has un-dispatched regressions, dispatch one
    if [ "$MODE" = fix ]; then
      [ "$("$DIR/claude-task.sh" state "regscan" 2>/dev/null)" = RUNNING ] && exit 0
      P="$(cat "$STATE/last-scan-path" 2>/dev/null)"
      [ -s "$P" ] && jq -e '.regressions' "$P" >/dev/null 2>&1 && "$0" hunt "$REPO_ARG" 2>/dev/null | grep -v "No new" || true
    fi ;;

  *) echo "usage: regressions.sh owned|scan|show|hunt|auto [repo] [--since <date>]" >&2; exit 1 ;;
esac
