#!/bin/bash
# research.sh — background research (web + reasoning) as a headless Claude task,
# so the brain never tries to browse or compare things inline.
#
#   research.sh start "<question>" [--context "<what it's for>"] [--for <slack target>]
#   research.sh list                      recent research, newest first
#   research.sh show [id|latest]          the finished write-up (or its status)
#   research.sh post [id|latest] [<slack target>]   post the write-up as @Margie  (OUTWARD-held)
#
# Results: ~/.margie/research/<id>/{question.txt,context.txt,for,result.md}.
# Honors MARGIE_DESCRIBE=1 on post (prints what would go where; sends nothing).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HOME/.margie/config.json"; R="$HOME/.margie/research"; mkdir -p "$R"
cfg() { jq -r ".$1 // empty" "$CFG" 2>/dev/null; }
slug() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-32; }
resolve() { local x="${1:-latest}"; [ "$x" = latest ] && x="$(ls -t "$R" | head -1)"; [ -d "$R/$x" ] || x="$(ls -t "$R" | grep -F -- "$x" | head -1)"; [ -n "$x" ] && [ -d "$R/$x" ] && echo "$x"; }
task_json() { # task_json <id> -> path of the task's result json (may be empty/absent)
  local m; for m in $(ls -t "$HOME/.margie/tasks"/*.meta 2>/dev/null); do
    if [ "$(jq -r '.tag // empty' "$m")" = "research:$1" ]; then echo "${m%.meta}.json"; return; fi
  done
}
cmd="${1:-list}"; shift || true
case "$cmd" in
  start)
    Q=""; CTX=""; FOR=""
    while [ $# -gt 0 ]; do case "$1" in
      --context) CTX="${2:-}"; shift 2 ;; --for) FOR="${2:-}"; shift 2 ;; *) Q="${Q:+$Q }$1"; shift ;; esac; done
    [ -z "$Q" ] && { echo "usage: research.sh start \"<question>\" [--context \"<use>\"] [--for <slack target>]" >&2; exit 1; }
    id="$(date +%s)-$(slug "$Q")"; mkdir -p "$R/$id"
    printf '%s' "$Q" > "$R/$id/question.txt"; printf '%s' "$CTX" > "$R/$id/context.txt"; printf '%s' "$FOR" > "$R/$id/for"
    P="You are a senior engineer doing a focused piece of research for Tom's team. Use web search and page fetches; cite the URL for every number.
QUESTION: $Q
${CTX:+CONTEXT (what it is for — tailor the recommendation to this): $CTX
}OUTPUT: a Slack-ready write-up in plain text with Slack formatting only (*bold*, • bullets, no markdown tables, no headings with #), at most 45 lines:
• one bullet block per option: name — pricing (per-message/segment, number rental, any registration fees), pros, cons, notable limits
• then *Recommendation* — one option and why, for the stated context, plus the biggest risk
• then *Sources* — the URLs used.
Facts only; say 'unverified' where a page didn't state it. Write NOTHING to disk."
    "$DIR/claude-task.sh" start "$HOME" "$P" --plan --no-subagents --model "$(cfg research_model | grep . || echo sonnet)" \
      --effort "$(cfg research_effort | grep . || echo medium)" --budget "$(cfg research_budget_usd | grep . || echo 2)" \
      --tag "research:$id" >/dev/null || exit 1
    echo "Research started, dearie ($id) — I'll say when it's done. Check: research.sh show $id" ;;
  list)
    for d in $(ls -t "$R" 2>/dev/null | head -10); do
      j="$(task_json "$d")"; st="running"; [ -n "$j" ] && [ -s "$j" ] && st="done"
      printf '%s  [%s]  %s%s\n' "$d" "$st" "$(cut -c1-80 "$R/$d/question.txt")" "$([ -s "$R/$d/for" ] && printf ' → %s' "$(cat "$R/$d/for")")"
    done ;;
  show)
    id="$(resolve "${1:-latest}")" || { echo "No such research, dearie." >&2; exit 1; }
    j="$(task_json "$id")"
    if [ -s "$R/$id/result.md" ]; then cat "$R/$id/result.md"
    elif [ -n "$j" ] && [ -s "$j" ]; then
      if [ "$(jq -r '.is_error // false' "$j")" = true ]; then echo "That research failed, dearie: $(jq -r '.result // "no detail"' "$j" | head -3)"; exit 1; fi
      jq -r '.result // empty' "$j" | tee "$R/$id/result.md"
      printf '\n(cost $%s)\n' "$(jq -r '.total_cost_usd // 0 | .*100 | round / 100' "$j")"
    else echo "Still researching, dearie — '$(cat "$R/$id/question.txt")' isn't finished yet."; fi ;;
  post)
    id="$(resolve "${1:-latest}")" || { echo "No such research, dearie." >&2; exit 1; }
    target="${2:-$(cat "$R/$id/for" 2>/dev/null)}"
    [ -z "$target" ] && { echo "Where should it go, dearie? research.sh post $id <#channel|@user|conversation id>" >&2; exit 1; }
    [ -s "$R/$id/result.md" ] || "$0" show "$id" >/dev/null 2>&1
    [ -s "$R/$id/result.md" ] || { echo "Nothing to post yet, dearie — that research isn't finished." >&2; exit 1; }
    BODY="$(cat "$R/$id/result.md")"
    if [ "${MARGIE_DESCRIBE:-0}" = 1 ]; then echo "would post the research write-up '$(cut -c1-60 "$R/$id/question.txt")' ($(printf '%s' "$BODY" | wc -l | tr -d ' ') lines) to $target as @Margie"; exit 0; fi
    "$DIR/slack.sh" send "$target: $BODY" ;;
  *) echo "usage: research.sh start \"<question>\" [--context c] [--for target] | list | show [id] | post [id] [target]" >&2; exit 1 ;;
esac
