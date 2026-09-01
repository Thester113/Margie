#!/bin/bash
# claude-task.sh — Margie's headless Claude Code harness: dispatch a background
# task, track it, read its result, follow up in the same session, or stop it.
# Interactive/watchable work goes through kickoff-claude.sh; this is for quiet
# background jobs Tom doesn't need to watch.
#
# Usage:
#   claude-task.sh start <dir> "<task>"          run `claude -p` in <dir>, detached; prints the task id
#   claude-task.sh status                         every task from the last 2 days: id, state, age, gist
#   claude-task.sh result [id|latest]             the finished task's full result text
#   claude-task.sh followup <id|latest> "<text>"  continue that task's Claude session with a new prompt
#   claude-task.sh log <id|latest> [n]            tail the raw log
#   claude-task.sh stop <id|latest>               stop a running task
#
# Each task lives in ~/.margie/tasks/<id>.{meta,log,json}. The json is Claude
# Code's --output-format json result (result text, session_id, cost, turns).
# Tasks run with --dangerously-skip-permissions: a headless run cannot answer
# permission prompts, and Tom's guard is that Margie only starts tasks he asked
# for (she confirms anything outward/irreversible first). Same stance as the
# watchable review sessions in review-pr.sh.
set -uo pipefail

TASKS="$HOME/.margie/tasks"; mkdir -p "$TASKS"
CLAUDE_BIN="${MARGIE_CLAUDE_BIN:-$(command -v claude || echo "$HOME/.local/bin/claude")}"
cmd="${1:-status}"; shift || true

slugify() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40; }
meta() { jq -r ".$2 // empty" "$TASKS/$1.meta" 2>/dev/null; }
latest() { ls -t "$TASKS"/*.meta 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null | sed 's/\.meta$//'; }
resolve_id() {
  local id="${1:-latest}"; [ "$id" = "latest" ] && id="$(latest)"
  [ -n "$id" ] && [ -f "$TASKS/$id.meta" ] || { echo "No such task${1:+ '$1'}, sir." >&2; return 1; }
  printf '%s' "$id"
}
running() { local pid; pid="$(meta "$1" pid)"; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
age() {
  local s d; s="$(meta "$1" started)"; d=$(( $(date +%s) - s ))
  if [ $d -lt 90 ]; then echo "${d}s"; elif [ $d -lt 5400 ]; then echo "$((d/60))m"; else echo "$((d/3600))h"; fi
}

launch() { # launch <id> <dir> <prompt> [extra claude flags...]
  local id="$1" dir="$2" prompt="$3"; shift 3
  local pf="$TASKS/$id.prompt"; printf '%s' "$prompt" > "$pf"
  ( cd "$dir" && nohup "$CLAUDE_BIN" -p "$(cat "$pf")" --output-format json --dangerously-skip-permissions "$@" \
      > "$TASKS/$id.json" 2> "$TASKS/$id.log" & echo $! > "$TASKS/$id.pid" )
  local pid; pid="$(cat "$TASKS/$id.pid")"; rm -f "$TASKS/$id.pid"
  jq -n --arg id "$id" --arg dir "$dir" --arg task "$prompt" --argjson pid "$pid" --argjson started "$(date +%s)" \
    '{id:$id, dir:$dir, task:$task, pid:$pid, started:$started}' > "$TASKS/$id.meta"
}

case "$cmd" in
  start)
    dir="${1:-}"; shift || true; task="$*"
    if [ -z "$dir" ] || [ -z "$task" ]; then echo "usage: claude-task.sh start <dir> \"<task>\"" >&2; exit 1; fi
    dir_abs="$(cd "${dir/#\~/$HOME}" 2>/dev/null && pwd)" || { echo "No such directory '$dir', sir." >&2; exit 1; }
    id="$(date +%s)-$(slugify "$task")"
    launch "$id" "$dir_abs" "$task"
    echo "Started background Claude task '$id' in $(basename "$dir_abs"), sir. Check it with: claude-task.sh status"
    ;;
  status|list)
    found=0
    for m in $(ls -t "$TASKS"/*.meta 2>/dev/null); do
      id="$(basename "$m" .meta)"; found=1
      [ $(( $(date +%s) - $(meta "$id" started) )) -gt 172800 ] && continue
      if running "$id"; then
        state="RUNNING"; gist="$(meta "$id" task | cut -c1-90)"
      else
        j="$TASKS/$id.json"
        if [ -s "$j" ] && jq -e . "$j" >/dev/null 2>&1; then
          if [ "$(jq -r '.is_error // false' "$j")" = "true" ]; then state="FAILED"; else state="DONE"; fi
          gist="$(jq -r '.result // ""' "$j" | tr '\n' ' ' | cut -c1-120)"
        else
          state="FAILED"; gist="$(tail -1 "$TASKS/$id.log" 2>/dev/null | cut -c1-120)"
        fi
      fi
      printf '%s  %-7s %4s  %s\n' "$id" "$state" "$(age "$id")" "$gist"
    done
    [ "$found" = 0 ] && echo "No background tasks, sir."
    ;;
  result)
    id="$(resolve_id "${1:-latest}")" || exit 1
    if running "$id"; then echo "Task '$id' is still running ($(age "$id")), sir."; exit 0; fi
    j="$TASKS/$id.json"
    if [ -s "$j" ] && jq -e . "$j" >/dev/null 2>&1; then
      jq -r '.result // "(no result text)"' "$j"
      printf '\n[%s turns, $%s, %ss, session %s]\n' \
        "$(jq -r '.num_turns // "?"' "$j")" \
        "$(jq -r '((.total_cost_usd // 0) * 1000 | round) / 1000' "$j")" \
        "$(jq -r '((.duration_ms // 0) / 1000) | round' "$j")" \
        "$(jq -r '.session_id // "?"' "$j")"
    else
      echo "Task '$id' produced no result, sir. Last log lines:"; tail -5 "$TASKS/$id.log" 2>/dev/null
    fi
    ;;
  followup|continue)
    id="$(resolve_id "${1:-latest}")" || exit 1; shift || true; text="$*"
    [ -z "$text" ] && { echo "usage: claude-task.sh followup <id|latest> \"<text>\"" >&2; exit 1; }
    if running "$id"; then echo "Task '$id' is still running, sir — wait for it or stop it first."; exit 1; fi
    sess="$(jq -r '.session_id // empty' "$TASKS/$id.json" 2>/dev/null)"
    [ -z "$sess" ] && { echo "Task '$id' has no session to continue, sir."; exit 1; }
    new="$(date +%s)-$(slugify "$text")"
    launch "$new" "$(meta "$id" dir)" "$text" --resume "$sess"
    echo "Follow-up sent as task '$new' (continuing $id), sir."
    ;;
  log)
    id="$(resolve_id "${1:-latest}")" || exit 1
    tail -n "${2:-30}" "$TASKS/$id.log" 2>/dev/null
    ;;
  stop)
    id="$(resolve_id "${1:-latest}")" || exit 1
    if running "$id"; then kill "$(meta "$id" pid)" && echo "Stopped task '$id', sir."; else echo "Task '$id' isn't running, sir."; fi
    ;;
  *)
    echo "usage: claude-task.sh start <dir> \"<task>\" | status | result [id] | followup <id> \"<text>\" | log [id] | stop [id]" >&2
    exit 1
    ;;
esac
