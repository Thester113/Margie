#!/bin/bash
# usage.sh — what Margie's Claude runs cost. Sources: ~/.margie/usage.log (brain
# turns, one line each with cost=$n) and ~/.margie/tasks/*.json (headless runs:
# planner, QA, MR drafts, ad-hoc tasks; total_cost_usd + modelUsage).
#
#   usage.sh today|week|all [--total]     --total prints just the number (for scripts)
set -uo pipefail
M="$HOME/.margie"; CFG="$M/config.json"
span="${1:-today}"; total_only=0; [ "${2:-}" = "--total" ] && total_only=1
case "$span" in
  today) SINCE="$(date -v0H -v0M -v0S +%s)" ;;
  week)  SINCE="$(date -v-6d -v0H -v0M -v0S +%s)" ;;
  all)   SINCE=0 ;;
  *) echo "usage: usage.sh today|week|all [--total]" >&2; exit 1 ;;
esac
# brain turns
SINCE_ISO="$(date -u -r "$SINCE" +%FT%T)"   # usage.log lines start with a UTC ISO timestamp
BRAIN="$(awk -v since="$SINCE_ISO" '$1 >= since { for (i=1;i<=NF;i++) if ($i ~ /^cost=\$/) { n++; sum+=substr($i,7) } }
  END { printf "%d %.4f", n+0, sum+0 }' "$M/usage.log" 2>/dev/null)"
BN="${BRAIN%% *}"; BC="${BRAIN##* }"
# headless tasks by category (tag prefix before ':')
TASKS="$(for j in "$M"/tasks/*.json; do
  [ -s "$j" ] || continue; meta="${j%.json}.meta"; [ -f "$meta" ] || continue
  st="$(jq -r '.started // 0' "$meta")"; [ "$st" -ge "$SINCE" ] || continue
  tag="$(jq -r '.tag // ""' "$meta" | sed 's/:.*//')"; [ -z "$tag" ] && tag="task"
  jq -r --arg tag "$tag" '"\($tag) \(.total_cost_usd // 0) \([.modelUsage // {} | keys[] | sub("claude-";"")] | join("+"))"' "$j"
done | awk '{ n[$1]++; c[$1]+=$2; m[$1]=$3 } END { for (k in n) printf "%s %d %.4f %s\n", k, n[k], c[k], m[k] }' | sort -k3 -rn)"
TC="$(printf '%s\n' "$TASKS" | awk '{ s+=$3 } END { printf "%.4f", s+0 }')"
TOTAL="$(echo "${BC:-0} + ${TC:-0}" | bc)"
if [ "$total_only" = 1 ]; then printf '%.2f\n' "$TOTAL"; exit 0; fi
DAILY="$(jq -r '.daily_budget_usd // empty' "$CFG" 2>/dev/null)"
printf 'Claude spend (%s): $%.2f%s\n' "$span" "$TOTAL" "${DAILY:+ of the \$$DAILY daily budget}"
printf '  %-10s %3d turns  $%.2f\n' "brain" "${BN:-0}" "${BC:-0}"
[ -n "$TASKS" ] && printf '%s\n' "$TASKS" | awk '{ printf "  %-10s %3d runs   $%.2f  (%s)\n", $1, $2, $3, $4 }'
exit 0
