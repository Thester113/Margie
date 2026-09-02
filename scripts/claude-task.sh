#!/bin/bash
# claude-task.sh — Margie's headless Claude Code harness: dispatch a background
# task, track it, read its result, follow up in the same session, or stop it.
# Interactive/watchable work goes through kickoff-claude.sh; this is for quiet
# background jobs Tom doesn't need to watch.
#
# Usage:
#   claude-task.sh start <dir> "<task>" [opts]   run `claude -p` in <dir>, detached; prints the task id
#     --schema <file>   ask for structured output (--json-schema); read it with `result --json`
#     --plan            read-only stage: --permission-mode plan instead of skip-permissions
#     --allow <tools>   extra --allowedTools (comma list)
#     --deny <tools>    --disallowedTools (comma list)
#     --model <m>       model override (omit = CLI default)
#     --tag <name>      label shown in status/notify (e.g. spec:d-123)
#     --out <file>      copy .structured_output there once the task finishes
#   claude-task.sh status                         every task from the last 2 days: id, state, age, gist
#   claude-task.sh result [id|latest]             the finished task's full result text
#   claude-task.sh followup <id|latest> "<text>"  continue that task's Claude session with a new prompt
#   claude-task.sh log <id|latest> [n]            tail the raw log
#   claude-task.sh stop <id|latest>               stop a running task
#   claude-task.sh detach <tag|id>                forget a task's --out/tag (superseded runs)
#   claude-task.sh notify                         one line per task newly finished since last
#                                                 call; SILENT otherwise (the daemon-poller contract)
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
by_tag() { # by_tag <tag> -> task id or empty
  local m
  for m in $(ls -t "$TASKS"/*.meta 2>/dev/null); do
    [ "$(jq -r '.tag // empty' "$m")" = "$1" ] && { basename "$m" .meta; return 0; }
  done
  return 1
}
age() {
  local s d; s="$(meta "$1" started)"; d=$(( $(date +%s) - s ))
  if [ $d -lt 90 ]; then echo "${d}s"; elif [ $d -lt 5400 ]; then echo "$((d/60))m"; else echo "$((d/3600))h"; fi
}

launch() { # launch <id> <dir> <prompt> [extra claude flags...]  (honors PERM/TAG/OUT set by start)
  local id="$1" dir="$2" prompt="$3"; shift 3
  local pf="$TASKS/$id.prompt"; printf '%s' "$prompt" > "$pf"
  ( cd "$dir" && nohup "$CLAUDE_BIN" -p "$(cat "$pf")" --output-format json "${PERM[@]:---dangerously-skip-permissions}" "$@" \
      > "$TASKS/$id.json" 2> "$TASKS/$id.log" & echo $! > "$TASKS/$id.pid" )
  local pid; pid="$(cat "$TASKS/$id.pid")"; rm -f "$TASKS/$id.pid"
  jq -n --arg id "$id" --arg dir "$dir" --arg task "$prompt" --arg tag "${TAG:-}" --arg out "${OUT:-}" \
     --argjson pid "$pid" --argjson started "$(date +%s)" \
    '{id:$id, dir:$dir, task:$task, tag:$tag, out:$out, pid:$pid, started:$started}' > "$TASKS/$id.meta"
}
# Copy structured output to its --out destination for any finished task that has one.
harvest() {
  local m id out j
  for m in "$TASKS"/*.meta; do
    [ -f "$m" ] || continue
    id="$(basename "$m" .meta)"
    out="$(meta "$id" out)"; [ -z "$out" ] && continue
    [ -f "$out" ] && continue
    running "$id" && continue
    j="$TASKS/$id.json"
    [ -s "$j" ] && jq -e '.structured_output' "$j" >/dev/null 2>&1 && jq '.structured_output' "$j" > "$out"
  done
}

case "$cmd" in
  start)
    PERM=(); TAG=""; OUT=""; EXTRA=(); dir=""; task=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --schema) EXTRA+=(--json-schema "$(cat "${2:?}")"); shift 2 ;;
        --plan)   PERM=(--permission-mode plan); shift ;;
        --allow)  EXTRA+=(--allowedTools "${2:?}"); shift 2 ;;
        --deny)   EXTRA+=(--disallowedTools "${2:?}"); shift 2 ;;
        --model)  EXTRA+=(--model "${2:?}"); shift 2 ;;
        --tag)    TAG="${2:?}"; shift 2 ;;
        --out)    OUT="${2:?}"; shift 2 ;;
        *) if [ -z "$dir" ]; then dir="$1"; else task="${task:+$task }$1"; fi; shift ;;
      esac
    done
    if [ -z "$dir" ] || [ -z "$task" ]; then echo "usage: claude-task.sh start <dir> \"<task>\" [--schema f] [--plan] [--allow t] [--deny t] [--model m] [--tag n] [--out f]" >&2; exit 1; fi
    # Default model for dispatched runs (claude_model in config) unless --model was given.
    if ! printf '%s\n' ${EXTRA[@]+"${EXTRA[@]}"} | grep -qx -- --model; then
      DM="$(jq -r '.claude_model // empty' "$HOME/.margie/config.json" 2>/dev/null)"
      [ -n "$DM" ] && EXTRA+=(--model "$DM")
    fi
    dir_abs="$(cd "${dir/#\~/$HOME}" 2>/dev/null && pwd)" || { echo "No such directory '$dir', sir." >&2; exit 1; }
    id="$(date +%s)-$(slugify "${TAG:-$task}")"
    launch "$id" "$dir_abs" "$task" ${EXTRA[@]+"${EXTRA[@]}"}
    echo "Started background Claude task '${TAG:-$id}' in $(basename "$dir_abs"), sir. Check it with: claude-task.sh status"
    ;;
  status|list)
    harvest
    found=0
    for m in $(ls -t "$TASKS"/*.meta 2>/dev/null); do
      id="$(basename "$m" .meta)"; found=1
      [ $(( $(date +%s) - $(meta "$id" started) )) -gt 172800 ] && continue
      if running "$id"; then
        state="RUNNING"; gist="$(meta "$id" task | tr '\n' ' ' | cut -c1-90)"
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
    JSON_OUT=0
    ARGS2=()
    for a in "$@"; do case "$a" in --json) JSON_OUT=1 ;; *) ARGS2+=("$a") ;; esac; done
    set -- ${ARGS2[@]+"${ARGS2[@]}"}
    id="$(resolve_id "${1:-latest}")" || exit 1
    harvest
    if running "$id"; then echo "Task '$id' is still running ($(age "$id")), sir."; exit 0; fi
    j="$TASKS/$id.json"
    if [ "$JSON_OUT" = 1 ]; then jq -e '.structured_output' "$j" 2>/dev/null || { echo "Task '$id' produced no structured output, sir." >&2; exit 1; }; exit 0; fi
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
  state)
    x="${1:-}"; [ -z "$x" ] && { echo "usage: claude-task.sh state <tag|id>" >&2; exit 1; }
    id="$x"; [ -f "$TASKS/$id.meta" ] || id="$(by_tag "$x" || true)"
    [ -z "$id" ] && { echo "NONE"; exit 0; }
    if running "$id"; then echo "RUNNING"
    elif [ -s "$TASKS/$id.json" ] && jq -e 'if .is_error then false else true end' "$TASKS/$id.json" >/dev/null 2>&1; then harvest; echo "DONE"
    else echo "FAILED"; fi
    ;;
  detach)
    # Forget a task's --out (and tag) so a superseded run can't re-deposit its output.
    x="${1:-}"; [ -z "$x" ] && { echo "usage: claude-task.sh detach <tag|id>" >&2; exit 1; }
    id="$x"; [ -f "$TASKS/$id.meta" ] || id="$(by_tag "$x" || true)"
    [ -z "$id" ] && { echo "NONE"; exit 0; }
    jq '.out = "" | .tag = (.tag + " (superseded)")' "$TASKS/$id.meta" > "$TASKS/$id.meta.tmp" && mv "$TASKS/$id.meta.tmp" "$TASKS/$id.meta"
    echo "detached $id"
    ;;
  notify)
    harvest
    SEEN="$TASKS/.notified"
    touch "$SEEN"
    for m in $(ls -t "$TASKS"/*.meta 2>/dev/null); do
      id="$(basename "$m" .meta)"
      running "$id" && continue
      grep -qxF "$id" "$SEEN" 2>/dev/null && continue
      j="$TASKS/$id.json"
      if [ -s "$j" ] && jq -e . "$j" >/dev/null 2>&1; then
        if [ "$(jq -r '.is_error // false' "$j")" = "true" ]; then st="FAILED"; else st="DONE"; fi
        gist="$(jq -r '.result // ""' "$j" | tr '\n' ' ' | cut -c1-110)"
      else st="FAILED"; gist="$(tail -1 "$TASKS/$id.log" 2>/dev/null | cut -c1-110)"; fi
      echo "Background task '$(meta "$id" tag | grep . || basename "$m" .meta)' finished: $st. $gist"
      echo "$id" >> "$SEEN"
    done
    ;;
  *)
    echo "usage: claude-task.sh start <dir> \"<task>\" [opts] | status | result [id] [--json] | followup <id> \"<text>\" | log [id] | stop [id] | notify" >&2
    exit 1
    ;;
esac
