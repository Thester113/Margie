#!/bin/bash
# scoreboard.sh — is Margie getting better? One weekly line for Tom (2026-09-25: "as close to
# flawless"): eval pass rate, corrections, what the answer gates caught.
#
#   scoreboard.sh week     print this week's scoreboard (last 7 days)
#   scoreboard.sh auto     poller: Mondays after 15:00 UTC, once a week, DM it to the owner
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; M="$HOME/.margie"; CFG="$M/config.json"
SINCE="$(date -u -v-7d +%Y-%m-%dT%H:%M 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT%H:%M)"
SINCE_STAMP="$(date -u -v-7d +%Y%m%d 2>/dev/null || date -u -d '7 days ago' +%Y%m%d)"

week() {
  # Evals: every run in the window, pass rate first → last.
  local evals="" first="" last="" runs=0
  for f in $(ls "$M"/evals/2*.json 2>/dev/null | sort); do
    s="$(basename "$f" .json | cut -c1-8)"; [ "$s" \< "$SINCE_STAMP" ] && continue
    r="$(jq -r '"\(.passed)/\(.total)"' "$f" 2>/dev/null)"; [ -z "$first" ] && first="$r"; last="$r"; runs=$((runs+1))
  done
  [ "$runs" -gt 0 ] && evals="evals $last (was $first a week ago, $runs runs)" || evals="no eval runs this week"
  # Jev log lines in the window ("2026-09-25T…" prefix compares as text).
  J="$(awk -v s="$SINCE" 'substr($1,1,16) >= s' "$M/jev.log" 2>/dev/null)"
  n() { printf '%s\n' "$J" | grep -c -- "$1" || true; }
  local corr lessons learned rechecks diverted fyi social
  corr="$(n 'outcome correction lesson@')"
  learned="$(awk -v s="$SINCE" -F'"at": "' 'NF>1 && substr($2,1,16) >= s' "$M/evals/learned.jsonl" 2>/dev/null | grep -vc '"dropped": true' || true)"
  rechecks="$(n 'outcome grounded recheck owner')"
  diverted="$(n 'outcome grounded tom speaker=')"
  fyi="$(grep -c 'FYI to the room per jev tone' "$M/slack-watch.log" 2>/dev/null || true)"
  echo "Margie's week: ${evals}. You corrected her ${corr} time(s); ${learned} of those became nightly checks. Her self-check re-verified ${rechecks} answer(s) to you and held back ${diverted} unconfirmed colleague reply/replies; she stayed out of ${fyi} FYI thread(s)."
}

case "${1:-week}" in
  week) week ;;
  auto)
    [ "$(date -u +%u)" = 1 ] && [ "$(date -u +%H)" -ge 15 ] || exit 0
    WK="$(date -u +%G-W%V)"; [ "$(cat "$M/scoreboard-sent" 2>/dev/null)" = "$WK" ] && exit 0
    echo "$WK" > "$M/scoreboard-sent"
    OWNER="$(jq -r '.owner_first_name // "Tom"' "$CFG" 2>/dev/null)"
    "$DIR/slack.sh" send "@$OWNER: $(week)" >/dev/null 2>&1 || true
    ;;
  *) echo "usage: scoreboard.sh week | auto" >&2; exit 64 ;;
esac
