#!/bin/bash
# dispatch.sh — Margie's product→architecture→QA dispatch pipeline.
#
# One dispatch = one feature request, thought through by a headless Claude Code
# planner IN the target repo, filed as a Notion ticket (+ test cases + spec
# page), implemented in a watchable Warp session on its own worktree branch,
# verified by a headless QA pass, and closed when the MR merges.
#
#   dispatch.sh spec <repo> "<request>" [--subdir backend]   start the planner (minutes)
#   dispatch.sh amend <id|latest> "<more context>"   re-plan the SAME dispatch with the request extended
#   dispatch.sh show [id|PT|latest]        the spec in <=6 spoken lines
#   dispatch.sh file <id>                  [held] ticket + test cases + spec page
#   dispatch.sh implement <id|PT>          kickoff worktree session; ticket -> In Progress
#   dispatch.sh go <id>                    [held] file + implement
#   dispatch.sh qa <id|PT> [--watch]       QA verifier in the worktree
#   dispatch.sh status [id|PT]             one line each; no arg = all active
#   dispatch.sh tick [--announce]          advance finished stages; silent when idle
#   dispatch.sh open <id|PT> [spec|qa|mr]  long text in a Warp tab
#   dispatch.sh close <id|PT>              [held] cancel the ticket
#   dispatch.sh describe <id> <stage>      what file/go/close would do
#
# State: ~/.margie/dispatch/<d-id>/{request.txt,context.md,spec.json,spec.md,
# body.md,testcases.json,ticket.json,tcmap.json,impl.json,qa.json,qa.md,mr.md,state}
# with a PT-### symlink once filed. `state` is one word.
set -uo pipefail

MDIR="$HOME/.margie/dispatch"; mkdir -p "$MDIR"
DIR="$(cd "$(dirname "$0")" && pwd)"
CFG="$HOME/.margie/config.json"
cfg() { jq -r ".$1 // empty" "$CFG" 2>/dev/null; }
cfgd() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }  # cfgd <key> <default>
desc() { if [ "${MARGIE_DESCRIBE:-0}" = "1" ]; then echo "$*"; exit 0; fi; }
slug() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-28; }
st() { # st <dir> [new-state]
  if [ $# -gt 1 ]; then printf '%s' "$2" > "$1/state"; else cat "$1/state" 2>/dev/null || echo "unknown"; fi
}
dmeta() { jq -r ".$2 // empty" "$1/d.json" 2>/dev/null; }
resolve_d() { # id | PT-### | latest | fuzzy word -> dispatch dir (follows the PT symlink)
  local x="${1:-latest}" p m
  [ "$x" = "latest" ] && { ls -td "$MDIR"/d-* 2>/dev/null | grep -v -- '--' | head -1; return; }
  p="$MDIR/$x"
  [ -e "$p" ] && { cd "$p" 2>/dev/null && pwd -P; return; }
  # Fuzzy: newest dispatch whose id or spec title mentions the word ("healthz").
  m="$(ls -td "$MDIR"/d-* 2>/dev/null | grep -v -- '--' | grep -i -- "$(printf '%s' "$x" | tr 'A-Z ' 'a-z-')" | head -1)"
  [ -z "$m" ] && m="$(ls -td "$MDIR"/d-*--* 2>/dev/null | grep -i -- "$(printf '%s' "$x" | tr 'A-Z ' 'a-z-')" | head -1)"
  [ -n "$m" ] && { echo "$m"; return; }
  for p in $(ls -td "$MDIR"/d-* 2>/dev/null); do
    jq -re --arg x "$x" '.title | ascii_downcase | contains($x | ascii_downcase)' "$p/spec.json" >/dev/null 2>&1 && { echo "$p"; return; }
  done
  echo ""
}
need_d() {
  D="$(resolve_d "${1:-latest}")"
  [ -n "$D" ] && [ -d "$D" ] || { echo "No such dispatch${1:+ '$1'}, dearie." >&2; exit 1; }
}
announce() { # announce "<spoken sentence>"  (file drop only with --announce / MARGIE_ANNOUNCE=1)
  echo "$1"
  if [ "${MARGIE_ANNOUNCE:-0}" = "1" ]; then
    mkdir -p "$HOME/.margie/announce"
    printf '%s' "$1" > "$HOME/.margie/announce/$(date +%s%N).txt"
  fi
}

# Render the ticket body (Amby's PT shape) and the fuller spec doc from spec.json.
render_md() { # render_md <dir>
  local d="$1" req
  req="$(tr '\n' ' ' < "$d/request.txt")"
  jq -r --arg req "$req" '
    def bl(a): (a // []) | map("- " + .) | join("\n");
    (if .parent_title then "Part of: " + .parent_title + " (ticket " + .ticket_key + ")\n\n" else "" end) +
    "> " + $req + "\n\n" +
    "## Use case\n" + (.use_case.story // "") +
      (if (.use_case.existing_use_case_match // null) then "\n(Belongs to existing use case: " + .use_case.existing_use_case_match + ")" else "" end) + "\n\n" +
    "## Goal\n" + .goal + "\n\n" +
    "## Scope\n" + bl(.scope) + "\n\n" +
    "## Out of scope\n" + bl(.out_of_scope) + "\n\n" +
    "## Architecture notes\n" + .architecture.approach + "\n" +
    "Subsystems: " + ((.architecture.subsystems // []) | join(", ")) + "\n" +
    ((.architecture.adr_refs // []) | map("- " + .ref + " — " + .how) | join("\n")) +
    (if ((.architecture.risks // []) | length) > 0 then "\nRisks:\n" + ((.architecture.risks) | map("- " + .risk + " → " + .mitigation) | join("\n")) else "" end) +
    (if (.architecture.adr_impact // "none") != "none" then "\nADR impact: " + .architecture.adr_impact else "" end) + "\n\n" +
    "## References\n" + bl(.architecture.decision_refs) +
      "\nAffected paths:\n" + bl(.architecture.affected_paths) + "\n\n" +
    "## Acceptance\n" + ((.acceptance_criteria // []) | map("- [ ] " + .) | join("\n")) + "\n\n" +
    "## QA plan\n" + ((.test_cases // []) | map("- " + .title + " (" + .case_type + ")") | join("\n")) +
    (if ((.open_questions // []) | length) > 0 then "\n\n## Open questions\n" + bl(.open_questions) else "" end)
  ' "$d/spec.json" > "$d/body.md"
  {
    jq -r '"# " + .title + "\n"' "$d/spec.json"
    cat "$d/body.md"
    echo
    echo "## Test case details"
    jq -r '(.test_cases // [])[] |
      "### " + .title + " (" + .case_type + (if .cannot_run_async then ", not async" else "" end) + ")\n" +
      "- Setup: " + .setup + "\n- Exercise: " + .exercise + "\n- Assertions: " + .assertions +
      "\n- Cleanup: " + .cleanup + "\n- Sabotage: " + .sabotage +
      (if (.test_file // "") != "" then "\n- File: " + .test_file else "" end)' "$d/spec.json"
    jq -r '"\n## Security\nRisk label: " + .security.risk_label +
      (if (.security.notes // "") != "" then "\n" + .security.notes else "" end)' "$d/spec.json"
  } > "$d/spec.md"
  jq -c '[.test_cases[] | {title, case_type, setup, exercise, assertions, cleanup,
                           cannot_run_async: (.cannot_run_async // false),
                           test_file: (.test_file // ""), sabotage}]' "$d/spec.json" > "$d/testcases.json"
}

launch_planner() { # launch_planner <dispatch dir> <workdir> "<request text>"
  local D="$1" WORKDIR="$2" REQ="$3" REPO
  REPO="$(dmeta "$D" repo)"
    CASE_TYPES="$("$DIR/notion.sh" schema testcases 2>/dev/null | awk -F'  +' '$1=="Case Type"{print $3}')"
    [ -z "$CASE_TYPES" ] && CASE_TYPES="ExUnit.Case|DataCase|ConnCase|Property-based|CommonTest"
    LABELS="$("$DIR/notion.sh" schema tickets 2>/dev/null | awk -F'  +' '$1=="Labels"{print $3}')"
    [ -z "$LABELS" ] && LABELS="Claude"

    P="$(cat "$DIR/prompts/spec-planner.md")"
    P="${P//'{{REQUEST}}'/$REQ}"
    P="${P//'{{CONTEXT}}'/$(cat "$D/context.md")}"
    P="${P//'{{CASE_TYPES}}'/$CASE_TYPES}"
    P="${P//'{{LABELS}}'/$LABELS}"
    # A re-plan revises the last spec instead of re-exploring the repo from scratch.
    if [ -s "$D/prev-spec.json" ]; then
      P="${P//'{{PREVIOUS}}'/$(printf 'PREVIOUS SPEC (revise it for the newest ADDENDUM(s); keep everything still valid, do not re-research what it already settled):\n%s' "$(cat "$D/prev-spec.json")")}"
    else
      P="${P//'{{PREVIOUS}}'/}"
    fi
    printf '%s' "$P" > "$D/planner-prompt.txt"

    MODEL_OPT=(); M="$(cfg planner_model)"; [ -n "$M" ] && MODEL_OPT=(--model "$M")
    SUB=(--no-subagents); [ "$(cfg planner_subagents)" = "true" ] && SUB=()
    date +%s > "$D/planner-started"; rm -f "$D/replan-pending"
    "$DIR/claude-task.sh" start "$WORKDIR" "$(cat "$D/planner-prompt.txt")" \
      --plan --schema "$DIR/schemas/spec.schema.json" ${SUB[@]+"${SUB[@]}"} \
      --effort "$(cfgd planner_effort medium)" --budget "$(cfgd dispatch_budget_usd 4)" \
      --allow "mcp__claude_ai_Notion__notion-fetch,mcp__claude_ai_Notion__notion-search,mcp__claude_ai_Notion__notion-query-data-sources" \
      --tag "spec:$(basename "$D")" --out "$D/spec.json" ${MODEL_OPT[@]+"${MODEL_OPT[@]}"} > /dev/null
}

# Superseded drafts stay visible under notion_drafts_parent (Tom wants the
# history in Notion): they are renamed, never archived.
supersede_draft() { # supersede_draft <dispatch dir> <label>   e.g. "Superseded 12:51" | "Filed as PT-812"
  local d="$1" label="$2" old title
  old="$(cat "$d/draft-page.id" 2>/dev/null)"; [ -z "$old" ] && return 0
  title="$(cat "$d/draft-page.title" 2>/dev/null)"; [ -z "$title" ] && title="Draft"
  "$DIR/notion.sh" page rename "$old" "$label — ${title#Draft — }" >/dev/null 2>&1 || true
  rm -f "$d/draft-page.id" "$d/draft-page.url" "$d/draft-page.title"
}

# Publish the finished spec as a read-only draft page under notion_drafts_parent
# so Tom can read the plan in Notion before "go". Earlier drafts are kept, renamed.
publish_draft() { # publish_draft <dispatch dir>
  local d="$1" parent title old url
  parent="$(cfg notion_drafts_parent)"; [ -z "$parent" ] && return 0
  spec_ready "$d" || return 0
  [ -s "$d/spec.md" ] || render_md "$d"
  title="Draft — $(jq -r .title "$d/spec.json")"
  supersede_draft "$d" "Superseded $(date +%b\ %-d\ %H:%M)"
  url="$("$DIR/notion.sh" page create "$title" --md "$d/spec.md" --parent "$parent" 2>/dev/null | grep -oE 'https://[^ ]+' | head -1)"
  [ -z "$url" ] && return 0
  printf '%s' "$url" > "$d/draft-page.url"; printf '%s' "$url" | grep -oE '[0-9a-f]{32}' | tail -1 > "$d/draft-page.id"; printf '%s' "$title" > "$d/draft-page.title"
  return 0
}

# Ticket breakdown (dispatch.sh breakdown): breakdown.json → breakdown.md
has_breakdown() { [ -s "$1/breakdown.json" ] && jq -e '.tickets | length >= 2' "$1/breakdown.json" >/dev/null 2>&1; }
render_breakdown() { # render_breakdown <dir>
  jq -r '
    def bl(a): (a // []) | map("- " + .) | join("\n");
    "## Ticket breakdown — " + .epic_title + "\n" + .summary_spoken + "\n\n" +
    ((.tickets // []) | map(
      "### " + .key + " — " + .title + " (" + .size + ", " + .risk_label + (if .spike then ", spike" else "" end) + ")" +
      (if (.depends_on | length) > 0 then "\nAfter: " + (.depends_on | join(", ")) else "" end) +
      "\n" + .goal + "\n\nScope:\n" + bl(.scope) +
      (if ((.out_of_scope // []) | length) > 0 then "\nOut of scope:\n" + bl(.out_of_scope) else "" end) +
      "\nAcceptance:\n" + ((.acceptance_criteria // []) | map("- [ ] " + .) | join("\n")) +
      "\nTests: " + ((.test_case_titles // []) | join("; ")) +
      (if (.notes // "") != "" then "\nNotes: " + .notes else "" end)
    ) | join("\n\n"))' "$1/breakdown.json" > "$1/breakdown.md"
}
# ── Per-ticket implementation. A breakdown's tickets become CHILD dispatches
# (d-<parent>--T2 …): each has its own scoped spec, ticket, branch, session, QA,
# MR and merge, and the next one starts when the previous merges. Spike tickets
# are human work: skipped and named as blockers. The umbrella closes last.
child_dir() { echo "$MDIR/$(basename "$1")--$2"; }
make_child() { # make_child <parent dir> <key>  → creates the child dispatch dir (idempotent)
  local d="$1" key="$2" c; c="$(child_dir "$d" "$key")"
  [ -d "$c" ] && { echo "$c"; return 0; }
  mkdir -p "$c"; echo "$(basename "$d")" > "$c/parent"; echo "$key" > "$c/key"
  jq -c --arg id "$(basename "$c")" '. + {id:$id}' "$d/d.json" > "$c/d.json"
  cp "$d/request.txt" "$c/request.txt"
  # scoped spec: the child's goal/scope/AC/tests over the parent's architecture and use case
  jq -c --arg key "$key" --slurpfile b "$d/breakdown.json" 'def norm: ascii_downcase | gsub("\\s*\\([^)]*\\)\\s*$";"") | gsub("[^a-z0-9]+";" ") | gsub("^ +| +$";"");
    ($b[0].tickets[] | select(.key==$key)) as $t
    | . + {title: $t.title, goal: $t.goal, scope: $t.scope, out_of_scope: ($t.out_of_scope // []),
           acceptance_criteria: $t.acceptance_criteria, estimate: $t.size,
           slug: ($t.title | ascii_downcase | gsub("[^a-z0-9]+";"-") | gsub("^-+|-+$";"") | .[0:28]),
           test_cases: (($t.test_case_titles | map(norm)) as $w | [.test_cases[] | select((.title | norm) as $x | $w | index($x))]),
           security: (.security + {risk_label: ($t.risk_label // .security.risk_label)}),
           open_questions: [], parent_title: .title, ticket_key: $key, spike: ($t.spike // false)}' "$d/spec.json" > "$c/spec.json"
  jq -c --arg key "$key" '.[] | select(.key==$key) | {pt, id, url}' "$d/tickets.json" > "$c/ticket.json"
  jq -c '[.test_cases[] | {title, case_type, setup, exercise, assertions, cleanup, cannot_run_async: (.cannot_run_async // false), test_file: (.test_file // ""), sabotage}]' "$c/spec.json" > "$c/testcases.json"
  [ -s "$d/child-$key-tcmap.json" ] && cp "$d/child-$key-tcmap.json" "$c/tcmap.json"
  [ -s "$d/docs-page.url" ] && cp "$d/docs-page.url" "$c/docs-page.url"
  render_md "$c"; st "$c" filed
  echo "$c"
}
next_child() { # next_child <parent dir> → key of the first ticket not yet started (skipping spikes), or ""
  local d="$1" key
  for key in $(jq -r '.tickets[] | select((.spike // false) | not) | .key' "$d/breakdown.json"); do
    [ -d "$(child_dir "$d" "$key")" ] || { echo "$key"; return 0; }
  done; echo ""
}
start_child() { # start_child <parent dir> <key>  → file+implement the child (branch from fresh main)
  local d="$1" key="$2" c; c="$(make_child "$d" "$key")"
  git -C "$(dmeta "$d" repo)" fetch -q origin "$(cfgd mr_target_branch main)" 2>/dev/null && git -C "$(dmeta "$d" repo)" checkout -q "$(cfgd mr_target_branch main)" 2>/dev/null && git -C "$(dmeta "$d" repo)" pull -q --ff-only 2>/dev/null || true
  "$0" implement "$(basename "$c")"
}
process_notes() { # process_notes <dir> — the team's written process for this repo, if Tom wrote one
  local f="$HOME/.margie/process/$(basename "$(dmeta "$1" repo)").md"
  [ -s "$f" ] && { printf '\n\nTEAM PROCESS FOR THIS REPO (follow it):\n'; cat "$f"; }
}
spec_text() { # spec_text <dir>  — spec.md plus the ticket breakdown when there is one
  cat "$1/spec.md"
  if [ -s "$1/key" ]; then
    echo; echo "THIS IS TICKET $(cat "$1/key") OF A LARGER PLAN. Implement ONLY this ticket's scope and acceptance criteria on this branch; earlier tickets are already merged on the target branch and later ones get their own sessions. Do not widen the scope."
  fi
  if has_breakdown "$1"; then echo; [ -s "$1/breakdown.md" ] || render_breakdown "$1"; cat "$1/breakdown.md"
    echo; echo "Work the tickets in dependency order, ONE MR per ticket (branch <branch_prefix>/<child PT>-<slug>); the umbrella ticket stays In Progress until the last child merges."; fi
}

# Umbrella and child tickets move together through the lifecycle; spike tickets
# (human verification work) are left where they are and named as blockers.
status_all() { # status_all <dispatch dir> "<Status>"
  local d="$1" stt="$2" pt
  pt="$(jq -r '.pt // empty' "$d/ticket.json" 2>/dev/null)"; [ -n "$pt" ] && "$DIR/notion.sh" ticket status "$pt" "$stt" >/dev/null 2>&1
  if [ -s "$d/epic.json" ]; then case "$stt" in "In Progress") "$DIR/notion.sh" epic status "$(jq -r .id "$d/epic.json")" Executing >/dev/null 2>&1 ;; Done) "$DIR/notion.sh" epic status "$(jq -r .id "$d/epic.json")" Done >/dev/null 2>&1 ;; Canceled) "$DIR/notion.sh" epic status "$(jq -r .id "$d/epic.json")" Backlog >/dev/null 2>&1 ;; esac; fi
  [ -s "$d/tickets.json" ] || return 0
  for pt in $(jq -r --slurpfile b "$d/breakdown.json" '.[] | select(.key as $k | ($b[0].tickets[] | select(.key==$k) | .spike // false) | not) | .pt' "$d/tickets.json" 2>/dev/null); do
    "$DIR/notion.sh" ticket status "$pt" "$stt" >/dev/null 2>&1
  done
}

spec_ready() { [ -s "$1/spec.json" ] && jq -e '.title and .goal and .acceptance_criteria and .test_cases' "$1/spec.json" >/dev/null 2>&1; }

cmd="${1:-status}"; shift || true

case "$cmd" in
  spec)
    REPO_ARG="${1:-}"; shift || true
    SUBDIR=""; REQ=""
    while [ $# -gt 0 ]; do
      case "$1" in --subdir) SUBDIR="${2:-}"; shift 2 ;; *) REQ="${REQ:+$REQ }$1"; shift ;; esac
    done
    [ -z "$REPO_ARG" ] || [ -z "$REQ" ] && { echo "usage: dispatch.sh spec <repo> \"<request>\" [--subdir <path>]" >&2; exit 1; }
    REPO="$("$DIR/resolve-repo.sh" "$REPO_ARG")" || exit 1
    [ -z "$SUBDIR" ] && SUBDIR="$(jq -r --arg r "$(basename "$REPO")" '.repo_subdirs[$r] // empty' "$CFG" 2>/dev/null)"
    WORKDIR="$REPO${SUBDIR:+/$SUBDIR}"
    [ -d "$WORKDIR" ] || { echo "No such directory $WORKDIR, dearie." >&2; exit 1; }
    # One planner per repo at a time: a refinement is `amend`, not a new dispatch.
    for other in "$MDIR"/d-*; do
      [ -d "$other" ] && [ "$(st "$other")" = "spec-running" ] && [ "$(dmeta "$other" repo)" = "$REPO" ] && {
        echo "A spec is already being drafted for $(basename "$REPO") ($(basename "$other")), dearie. To add context: dispatch.sh amend $(basename "$other") \"…\"; to replace it: dispatch.sh close $(basename "$other") first."
        exit 1; }
    done
    ID="d-$(date +%s)-$(slug "$REQ")"
    D="$MDIR/$ID"; mkdir -p "$D"
    printf '%s' "$REQ" > "$D/request.txt"
    jq -n --arg repo "$REPO" --arg subdir "$SUBDIR" --arg id "$ID" '{id:$id, repo:$repo, subdir:$subdir}' > "$D/d.json"

    # Context for the planner: recent tickets/use cases/decision refs + repo shape.
    {
      echo "### Recent tickets (title [PT] (status))"
      "$DIR/notion.sh" rows tickets 25 2>/dev/null || echo "(Notion tickets not reachable)"
      echo; echo "### Use cases on record"
      "$DIR/notion.sh" rows usecases 40 2>/dev/null || echo "(none reachable)"
      echo; echo "### Decision register (cite these refs)"
      "$DIR/notion.sh" rows decisions 40 2>/dev/null || echo "(none reachable)"
      echo; echo "### Open questions"
      "$DIR/notion.sh" rows questions 30 2>/dev/null || echo "(none reachable)"
      echo; echo "### ADRs in the repo"
      ls "$WORKDIR/adrs" 2>/dev/null || ls "$WORKDIR/docs/adr" 2>/dev/null || echo "(no adrs dir)"
      echo; echo "### Recent commits"
      git -C "$REPO" log --oneline -15 2>/dev/null
    } > "$D/context.md"

    launch_planner "$D" "$WORKDIR" "$REQ"
    st "$D" spec-running
    echo "Drafting the spec for '$ID' in $(basename "$REPO")${SUBDIR:+/$SUBDIR}, dearie — product, architecture and QA. A few minutes; check with: dispatch.sh show"
    ;;
  amend)
    need_d "${1:-latest}"; shift || true
    EXTRA="$*"; [ -z "$EXTRA" ] && { echo "usage: dispatch.sh amend <id|latest> \"<more context>\"" >&2; exit 1; }
    case "$(st "$D")" in
      spec-running|spec-ready|spec-failed) ;;
      *) echo "That dispatch is already past planning ($(st "$D")), dearie — amendments go to the session or the ticket." >&2; exit 1 ;;
    esac
    # Supersede any previous planner run for this dispatch: stop it if running and
    # detach its --out so a finished one can't re-deposit the old spec.
    # A planner that started less than 10 minutes ago is replaced on the spot (little
    # is lost and nothing would be running otherwise); an older one runs to completion
    # and the new context is folded into the next re-plan.
    LAST="$(cat "$D/planner-started" 2>/dev/null || echo 0)"
    RESTART=0
    if [ "$("$DIR/claude-task.sh" state "spec:$(basename "$D")")" = "RUNNING" ]; then
      if [ $(( $(date +%s) - LAST )) -lt 600 ]; then
        "$DIR/claude-task.sh" stop "spec:$(basename "$D")" >/dev/null 2>&1 || true; RESTART=1
      else
        printf '\n\nADDENDUM (%s): %s' "$(date -u +%FT%TZ)" "$EXTRA" >> "$D/request.txt"
        touch "$D/replan-pending"
        echo "Noted, dearie — the current planning run is well along, so I've added that to the request and will re-plan in one go once it finishes."
        exit 0
      fi
    fi
    while [ "$("$DIR/claude-task.sh" state "spec:$(basename "$D")")" != "NONE" ]; do
      "$DIR/claude-task.sh" detach "spec:$(basename "$D")" >/dev/null 2>&1 || break
    done
    printf '\n\nADDENDUM (%s): %s' "$(date -u +%FT%TZ)" "$EXTRA" >> "$D/request.txt"
    # Coalesce: each planner run is a multi-minute Claude session. If one ran in the
    # last 20 minutes (and we didn't just replace it), queue the context — tick re-plans once things go quiet.
    if [ "$RESTART" = 0 ] && [ $(( $(date +%s) - LAST )) -lt 1200 ]; then
      touch "$D/replan-pending"
      echo "Noted, dearie — I've added that to the spec's request; I'll re-plan in one go shortly rather than start another run right now."
      exit 0
    fi
    [ -s "$D/spec.json" ] && cp "$D/spec.json" "$D/prev-spec.json"; rm -f "$D/spec.json" "$D/spec.md" "$D/body.md" "$D/breakdown.json" "$D/breakdown.md" "$D/breakdown-running"  # a re-plan invalidates the ticket breakdown
    supersede_draft "$D" "Superseded $(date +%b\ %-d\ %H:%M)"
    REPO="$(dmeta "$D" repo)"; SUBDIR="$(dmeta "$D" subdir)"; WORKDIR="$REPO${SUBDIR:+/$SUBDIR}"
    launch_planner "$D" "$WORKDIR" "$(cat "$D/request.txt")"
    st "$D" spec-running
    echo "Amended and re-planning '$(basename "$D")' with the extra context, dearie — a few minutes; check with: dispatch.sh show"
    ;;
  show)
    need_d "${1:-latest}"
    if ! spec_ready "$D"; then
      case "$(st "$D")" in
        spec-running) echo "The spec is still being drafted, dearie." ;;
        spec-failed)  echo "The spec run failed, dearie — see claude-task.sh log." ;;
        *) echo "No spec on this dispatch yet, dearie." ;;
      esac
      exit 0
    fi
    [ -s "$D/draft-page.url" ] || publish_draft "$D"
    jq -r '
      "Spec: " + .title + " (" + .estimate + ", " + .security.risk_label + ")",
      "Goal: " + .goal,
      "Story: " + .use_case.story,
      ("Scope: " + ((.scope | length | tostring)) + " items, " + ((.acceptance_criteria | length | tostring)) + " acceptance criteria, " + ((.test_cases | length | tostring)) + " test cases"),
      (if (.open_questions | length) > 0 then "Open questions: " + (.open_questions | join(" | ")) else "No open questions." end)
    ' "$D/spec.json"
    if has_breakdown "$D"; then
      jq -r '"Tickets (" + (.tickets|length|tostring) + "): " + (.tickets | map(.key + " " + .title + " (" + .size + (if .spike then ", spike" else "" end) + (if (.depends_on|length)>0 then ", after " + (.depends_on|join("/")) else "" end) + ")") | join("; "))' "$D/breakdown.json"
      echo "Say \"go\" to file the umbrella ticket plus those tickets and start Claude, dearie."
    elif [ -f "$D/breakdown-running" ]; then echo "The ticket breakdown is still being drafted, dearie."
    else
      echo "Say \"go\" to file the ticket and start Claude, dearie$( [ "$(jq -r .estimate "$D/spec.json")" = L ] || [ "$(jq -r .estimate "$D/spec.json")" = XL ] && echo " — or \"break it into tickets\" first (dispatch.sh breakdown), it's a big one")."
    fi
    [ -s "$D/draft-page.url" ] && echo "Read the full draft in Notion: $(cat "$D/draft-page.url")"
    ;;
  breakdown)
    need_d "${1:-latest}"
    spec_ready "$D" || { echo "The spec isn't ready yet, dearie — break it down once it is." >&2; exit 1; }
    case "$(st "$D")" in spec-ready|spec-failed|spec-running) ;; *) echo "Already past planning ($(st "$D")), dearie — split the work in the ticket instead." >&2; exit 1 ;; esac
    [ -s "$D/spec.md" ] || render_md "$D"
    P="$(cat "$DIR/prompts/breakdown-planner.md")"
    P="${P//'{{SPEC}}'/$(spec_text "$D")$(process_notes "$D")}"
    P="${P//'{{REQUEST}}'/$(cat "$D/request.txt")}"
    while [ "$("$DIR/claude-task.sh" state "breakdown:$(basename "$D")")" != "NONE" ]; do "$DIR/claude-task.sh" detach "breakdown:$(basename "$D")" >/dev/null 2>&1 || break; done
    rm -f "$D/breakdown.json" "$D/breakdown.md"; touch "$D/breakdown-running"
    REPO="$(dmeta "$D" repo)"; SUBDIR="$(dmeta "$D" subdir)"; WORKDIR="$REPO${SUBDIR:+/$SUBDIR}"
    MODEL_OPT=(); M="$(cfg planner_model)"; [ -n "$M" ] && MODEL_OPT=(--model "$M")
    "$DIR/claude-task.sh" start "$WORKDIR" "$P" --plan --no-subagents --schema "$DIR/schemas/breakdown.schema.json" \
      --effort "$(cfgd planner_effort medium)" --budget "$(cfgd dispatch_budget_usd 4)" \
      --tag "breakdown:$(basename "$D")" --out "$D/breakdown.json" ${MODEL_OPT[@]+"${MODEL_OPT[@]}"} > /dev/null || { rm -f "$D/breakdown-running"; exit 1; }
    echo "Splitting \"$(jq -r .title "$D/spec.json")\" into tickets, dearie — a few minutes; I'll say when the list is ready." ;;

  file)
    need_d "${1:-latest}"
    spec_ready "$D" || { echo "The spec isn't ready yet, dearie." >&2; exit 1; }
    TITLE="$(jq -r .title "$D/spec.json")"
    NTC="$(jq '.test_cases | length' "$D/spec.json")"
    RISK="$(jq -r .security.risk_label "$D/spec.json")"
    if has_breakdown "$D"; then desc "would file the umbrella ticket \"$TITLE\" plus $(jq '.tickets|length' "$D/breakdown.json") tickets ($(jq -r '.tickets|map(.key + " " + .title)|join("; ")' "$D/breakdown.json")) with Blocked-By ordering, $NTC test cases spread across them, and a spec page, in the Tickets database"
    else desc "would file Notion ticket \"$TITLE\" ($NTC test cases, $RISK) plus a spec page, in the Tickets database"; fi
    render_md "$D"
    PRIO="$(jq -r .priority "$D/spec.json")"
    LBLS="$(jq -r '.labels | join(",")' "$D/spec.json")"
    # Relate to an existing use case when the planner named one.
    UCOPT=()
    UCNAME="$(jq -r '.use_case.existing_use_case_match // empty' "$D/spec.json")"
    if [ -n "$UCNAME" ]; then
      UCID="$("$DIR/notion.sh" rows usecases 100 2>/dev/null | grep -iF "$UCNAME" >/dev/null && \
        "$DIR/notion.sh" query "$(cfg notion_usecases_ds)" "$UCNAME" 2>/dev/null | head -1 | grep -oE '\[[0-9a-f]{32}\]' | tr -d '[]')" || true
      [ -n "${UCID:-}" ] && UCOPT=(--usecase "$UCID")
    fi
    OUT="$("$DIR/notion.sh" ticket create "$TITLE" --md "$D/body.md" --priority "$PRIO" --labels "$LBLS" ${UCOPT[@]+"${UCOPT[@]}"})" || exit 1
    echo "$OUT" | head -1
    printf '%s\n' "$OUT" | tail -1 > "$D/ticket.json"
    PT="$(jq -r .pt "$D/ticket.json")"; TURL="$(jq -r .url "$D/ticket.json")"; TID="$(jq -r .id "$D/ticket.json")"
    if has_breakdown "$D"; then
      # Child tickets in dependency order; test cases go to the child that owns them.
      [ -s "$D/breakdown.md" ] || render_breakdown "$D"
      echo "[]" > "$D/tickets.json"; : > "$D/tickets.md"
      N="$(jq '.tickets|length' "$D/breakdown.json")"
      for ((i=0; i<N; i++)); do
        T="$(jq -c ".tickets[$i]" "$D/breakdown.json")"; KEY="$(jq -r .key <<<"$T")"
        jq -r --arg pt "$PT" --arg url "$TURL" '
          def bl(a): (a // []) | map("- " + .) | join("\n");
          "> Part of " + $pt + " — " + $url + "\n\n## Goal\n" + .goal +
          "\n\n## Scope\n" + bl(.scope) +
          (if ((.out_of_scope // []) | length) > 0 then "\n\n## Out of scope\n" + bl(.out_of_scope) else "" end) +
          (if (.depends_on | length) > 0 then "\n\n## Depends on\n" + bl(.depends_on) else "" end) +
          "\n\n## Acceptance\n" + ((.acceptance_criteria // []) | map("- [ ] " + .) | join("\n")) +
          "\n\n## QA plan\n" + ((.test_case_titles // []) | map("- " + .) | join("\n")) +
          (if (.notes // "") != "" then "\n\n## Notes\n" + .notes else "" end)' <<<"$T" > "$D/child-$KEY.md"
        CT="$(jq -r .title <<<"$T")"
        COUT="$("$DIR/notion.sh" ticket create "$CT" --md "$D/child-$KEY.md" --priority "$PRIO" --labels "$LBLS" ${UCOPT[@]+"${UCOPT[@]}"})" || exit 1
        echo "$COUT" | head -1
        CJ="$(printf '%s\n' "$COUT" | tail -1)"; CPT="$(jq -r .pt <<<"$CJ")"
        jq -c --argjson t "$(jq -c --arg k "$KEY" '. + {key:$k}' <<<"$CJ")" '. + [$t]' "$D/tickets.json" > "$D/tickets.json.tmp" && mv "$D/tickets.json.tmp" "$D/tickets.json"
        printf -- '- %s — %s (%s): %s\n' "$CPT" "$CT" "$KEY" "$(jq -r .url <<<"$CJ")" >> "$D/tickets.md"
        jq -c --argjson want "$(jq -c '.test_case_titles // []' <<<"$T")" 'def norm: ascii_downcase | gsub("\\s*\\([^)]*\\)\\s*$";"") | gsub("[^a-z0-9]+";" ") | gsub("^ +| +$";""); ($want | map(norm)) as $w | [.[] | select((.title | norm) as $t | $w | index($t))]' "$D/testcases.json" > "$D/child-$KEY-tc.json"
        if [ "$(jq 'length' "$D/child-$KEY-tc.json")" -gt 0 ]; then
          "$DIR/notion.sh" testcase add "$CPT" --json "$D/child-$KEY-tc.json" | { read -r line1; echo "$line1"; cat > "$D/child-$KEY-tcmap.json"; }
        fi
      done
      # Blocked-By relations from depends_on, now that every child has a PT.
      for ((i=0; i<N; i++)); do
        KEY="$(jq -r ".tickets[$i].key" "$D/breakdown.json")"; DEPS="$(jq -r ".tickets[$i].depends_on | join(\",\")" "$D/breakdown.json")"
        [ -z "$DEPS" ] && continue
        CPT="$(jq -r --arg k "$KEY" '.[] | select(.key==$k) | .pt' "$D/tickets.json")"
        BB="$(for d in $(tr ',' ' ' <<<"$DEPS"); do jq -r --arg k "$d" '.[] | select(.key==$k) | .pt' "$D/tickets.json"; done | paste -sd, -)"
        [ -n "$BB" ] && "$DIR/notion.sh" ticket relate "$CPT" --blocked-by "$BB" >/dev/null && echo "$CPT blocked by $BB"
      done
      # the umbrella's test-case map is the union of the children's (QA updates statuses through it)
      jq -s 'add // {}' "$D"/child-*-tcmap.json > "$D/tcmap.json" 2>/dev/null || echo '{}' > "$D/tcmap.json"
      if [ -n "$(cfg notion_epics_ds)" ]; then
        ALLPT="$PT,$(jq -r 'map(.pt) | join(",")' "$D/tickets.json")"
        if [ -s "$D/epic.json" ]; then
          # an epic.json placed here beforehand means: file under THAT existing Epic
          "$DIR/notion.sh" epic relate "$(jq -r .id "$D/epic.json")" --tickets "$ALLPT,$(cat "$D/epic-existing-tickets" 2>/dev/null)" >/dev/null 2>&1 && echo "Linked to the existing Epic: $(jq -r .url "$D/epic.json")"
        else
          EOUT="$("$DIR/notion.sh" epic create "$TITLE" --md "$D/body.md" --status Planning --tickets "$ALLPT" 2>/dev/null)" && { echo "$EOUT" | head -1; printf '%s\n' "$EOUT" | tail -1 > "$D/epic.json"; }
        fi
      fi
      { echo "## Tickets"; cat "$D/tickets.md"; } > "$D/umbrella-tickets.md"
      "$DIR/notion.sh" ticket append "$PT" --md "$D/umbrella-tickets.md" >/dev/null 2>&1 || true
      cat "$D/breakdown.md" >> "$D/spec.md"
    else
      "$DIR/notion.sh" testcase add "$PT" --json "$D/testcases.json" | { read -r line1; echo "$line1"; cat > "$D/tcmap.json"; }
    fi
    DOCS="$("$DIR/notion.sh" page create "$PT — Spec & QA plan" --md "$D/spec.md" --parent "$TID")" && echo "$DOCS"
    # The draft page is superseded by the ticket's own spec page; it stays, renamed.
    supersede_draft "$D" "Filed as $PT"
    printf '%s' "$DOCS" | grep -oE 'https://[^ ]+' | head -1 > "$D/docs-page.url" || true
    ln -sfn "$D" "$MDIR/$PT"
    st "$D" filed
    echo "Filed $PT, dearie: $TURL"
    ;;

  implement)
    need_d "${1:-latest}"
    [ -s "$D/ticket.json" ] || { echo "File the ticket first, dearie (dispatch.sh file)." >&2; exit 1; }
    PT="$(jq -r .pt "$D/ticket.json")"; TURL="$(jq -r .url "$D/ticket.json")"
    REPO="$(dmeta "$D" repo)"; SUBDIR="$(dmeta "$D" subdir)"
    BRANCH="$(cfg branch_prefix)"; BRANCH="${BRANCH:-margie}/$PT-$(jq -r .slug "$D/spec.json")"
    P="$(cat "$DIR/prompts/implement.md")"
    P="${P//'{{PT}}'/$PT}"
    P="${P//'{{TICKET_URL}}'/$TURL}"
    P="${P//'{{BRANCH}}'/$BRANCH}"
    P="${P//'{{MR_FILE}}'/$D/mr.md}"
    P="${P//'{{SPEC}}'/$(spec_text "$D")$(process_notes "$D")}"
    KOUT="$("$DIR/kickoff-claude.sh" "$REPO" --worktree "$BRANCH" ${SUBDIR:+--subdir "$SUBDIR"} "$P")" || exit 1
    echo "$KOUT" | tail -1
    WT="$HOME/.margie/worktrees/$(basename "$REPO")__$(printf '%s' "$BRANCH" | tr '/ ' '--')"
    jq -n --arg branch "$BRANCH" --arg wt "$WT" '{branch:$branch, worktree:$wt}' > "$D/impl.json"
    status_all "$D" "In Progress" && echo "$PT is In Progress$( [ -s "$D/tickets.json" ] && echo " (and its $(jq length "$D/tickets.json") child tickets)")."
    st "$D" implementing
    ;;

  go)
    need_d "${1:-latest}"
    spec_ready "$D" || { echo "The spec isn't ready yet, dearie." >&2; exit 1; }
    TITLE="$(jq -r .title "$D/spec.json")"
    case "$(jq -r '.estimate // ""' "$D/spec.json")" in L|XL)
      if ! has_breakdown "$D"; then
        [ -f "$D/breakdown-running" ] || "$0" breakdown "$(basename "$D")" >/dev/null 2>&1
        echo "That spec is $(jq -r .estimate "$D/spec.json") — I'm splitting it into tickets first so the MRs stay small, dearie. Say \"go\" again once the ticket list is up (a few minutes)."; exit 1
      fi ;;
    esac
    if has_breakdown "$D"; then desc "would file the umbrella ticket \"$TITLE\" plus $(jq '.tickets|length' "$D/breakdown.json") child tickets in Blocked-By order ($(jq -r '.tickets|map(.key + " " + .title)|join("; ")' "$D/breakdown.json")), $(jq '.test_cases|length' "$D/spec.json") test cases spread across them, a spec page, then start ONE Claude Code session on branch $(cfg branch_prefix | grep . || echo margie)/PT-…-$(jq -r .slug "$D/spec.json") in a worktree that works the tickets in order, one MR each"
    else desc "would file Notion ticket \"$TITLE\" with $(jq '.test_cases|length' "$D/spec.json") test cases and a spec page, then start a Claude Code session on branch $(cfg branch_prefix | grep . || echo margie)/PT-…-$(jq -r .slug "$D/spec.json") in a worktree"; fi
    "$0" file "$(basename "$D")" || exit 1
    if has_breakdown "$D"; then
      st "$D" implementing; status_all "$D" "In Progress" >/dev/null 2>&1
      SP="$(jq -r '[.tickets[] | select(.spike // false) | .key + " " + .title] | join("; ")' "$D/breakdown.json")"
      [ -n "$SP" ] && echo "On you, dearie (spike work, not automated): $SP."
      K="$(next_child "$D")"; [ -n "$K" ] && start_child "$D" "$K"
    else
      "$0" implement "$(basename "$D")"
    fi
    ;;

  qa)
    WATCH=0; ARGS=()
    for a in "$@"; do case "$a" in --watch) WATCH=1 ;; *) ARGS+=("$a") ;; esac; done
    need_d "${ARGS[0]:-latest}"
    [ -s "$D/impl.json" ] || { echo "Nothing implemented to verify on this dispatch, dearie." >&2; exit 1; }
    PT="$(jq -r .pt "$D/ticket.json")"; TURL="$(jq -r .url "$D/ticket.json")"
    WT="$(jq -r .worktree "$D/impl.json")"; SUBDIR="$(dmeta "$D" subdir)"
    [ -d "$WT" ] || { echo "The worktree is gone, dearie ($WT)." >&2; exit 1; }
    P="$(cat "$DIR/prompts/qa-verifier.md")"
    P="${P//'{{PT}}'/$PT}"
    P="${P//'{{TICKET_URL}}'/$TURL}"
    P="${P//'{{SPEC}}'/$(spec_text "$D")$(process_notes "$D")}"
    if [ "$WATCH" = 1 ]; then
      "$DIR/kickoff-claude.sh" "$WT" ${SUBDIR:+--subdir "$SUBDIR"} "$P" | tail -1
    else
      MODEL_OPT=(); M="$(cfg qa_model)"; [ -n "$M" ] && MODEL_OPT=(--model "$M")
      "$DIR/claude-task.sh" start "$WT${SUBDIR:+/$SUBDIR}" "$P" \
        --deny "Edit,Write,NotebookEdit" --no-subagents --schema "$DIR/schemas/qa.schema.json" \
        --effort "$(cfgd qa_effort medium)" --budget "$(cfgd dispatch_budget_usd 4)" \
        --tag "qa:$(basename "$D")" --out "$D/qa.json" ${MODEL_OPT[@]+"${MODEL_OPT[@]}"} > /dev/null
      st "$D" qa-running
      echo "QA verification is running on $PT, dearie — I'll report the verdict."
    fi
    ;;

  brief)
    # One screen that answers "what's the status of X, what's done, what's next" — the
    # brain reads THIS instead of rummaging through Notion/Jira/forge.
    need_d "${1:-latest}"
    S="$(st "$D")"; PT="$(jq -r '.pt // empty' "$D/ticket.json" 2>/dev/null)"; T="$(jq -r '.title // "(no spec yet)"' "$D/spec.json" 2>/dev/null)"
    echo "== $T"; echo "Ticket: ${PT:-not filed}$( [ -s "$D/ticket.json" ] && echo " — $(jq -r .url "$D/ticket.json")")   Stage: $S"
    [ -s "$D/epic.json" ] && echo "Epic: $(jq -r .url "$D/epic.json")"
    if [ -s "$D/mr.json" ]; then
      MST="$( [ -s "$D/mr-check.json" ] && jq -r '"state \(.state), pipeline \(.pipeline), \(.unresolved) open threads"' "$D/mr-check.json")"
      [ "$S" = closed ] && MST="MERGED"
      echo "MR: !$(jq -r .iid "$D/mr.json") — $MST — $(jq -r .url "$D/mr.json")"
    fi
    if has_breakdown "$D"; then
      echo "Tickets:"
      jq -r --slurpfile t "$D/tickets.json" '.tickets[] | .key as $k | "  \(( $t[0][] | select(.key==$k) | .pt ) // $k)  \(.title)  [\(.size)\(if .spike then ", spike — human work" else "" end)]" + (if ((.needs_from_owner // []) | length) > 0 then "  needs from Tom: " + (.needs_from_owner | join("; ")) else "" end)' "$D/breakdown.json" 2>/dev/null
      for c in "$MDIR/$(basename "$D")--"*; do [ -d "$c" ] && echo "  ↳ $(cat "$c/key") $(st "$c")$( [ -s "$c/mr.json" ] && echo " MR !$(jq -r .iid "$c/mr.json")")"; done
    fi
    ONTOM="$(jq -r '[.tickets[]? | select(.spike // false) | .title + (if ((.needs_from_owner // []) | length) > 0 then " (needs: " + (.needs_from_owner | join("; ")) + ")" else "" end)] | join(" | ")' "$D/breakdown.json" 2>/dev/null)"
    [ -n "$ONTOM" ] && [ "$S" != closed ] && echo "On Tom: $ONTOM"
    [ -n "$ONTOM" ] && [ "$S" = closed ] && echo "Still on Tom after the merge: $ONTOM"
    echo "Assumptions the spec made (say if any is wrong; nothing is being asked):"
    jq -r '.open_questions[]? | "  - " + (.[0:220])' "$D/spec.json" 2>/dev/null | head -8
    echo "Next:"
    case "$S" in
      spec-running) echo "  planner is drafting the spec" ;;
      spec-ready) echo "  $( has_breakdown "$D" && echo 'say "go" to file the Epic + tickets and start ticket 1' || echo 'say "go" to file the ticket and start the session' )" ;;
      filed|implementing) echo "  coding session in progress; QA and the MR follow automatically" ;;
      qa-running) echo "  QA verifier running" ;; qa-pass) echo "  MR under review; merge is automatic when green with all threads resolved" ;;
      qa-fail) echo "  findings sent back to the session" ;;
      closed) echo "  merged and done — only the human items above remain" ;;
      *) echo "  $S" ;;
    esac
    ;;
  status)
    if [ -n "${1:-}" ]; then DIRS="$(resolve_d "$1")"; else DIRS="$(ls -td "$MDIR"/d-* 2>/dev/null)"; fi
    [ -z "$DIRS" ] && { echo "No dispatches, dearie."; exit 0; }
    FOUND=0
    for D in $DIRS; do
      [ -d "$D" ] || continue
      S="$(st "$D")"
      [ -z "${1:-}" ] && [ "$S" = "closed" ] && continue
      FOUND=1
      PT="$(jq -r '.pt // empty' "$D/ticket.json" 2>/dev/null)"
      LINE="${PT:-$(basename "$D")}: $S"
      if [ "$S" = "implementing" ] && [ -s "$D/impl.json" ]; then
        BR="$(jq -r .branch "$D/impl.json")"
        SESS="margie-$(printf '%s' "$BR" | tr '/ ' '--')"
        tmux has-session -t "$SESS" 2>/dev/null && LINE="$LINE, session live" || LINE="$LINE, session ended"
      fi
      [ -s "$D/key" ] && LINE="  ↳ $(cat "$D/key") $LINE"
      if has_breakdown "$D" && [ ! -s "$D/impl.json" ]; then
        DONE=0; TOT="$(jq '[.tickets[] | select((.spike // false) | not)] | length' "$D/breakdown.json")"
        for c in "$MDIR/$(basename "$D")--"*; do [ -d "$c" ] && [ "$(st "$c")" = closed ] && DONE=$((DONE+1)); done
        LINE="$LINE, tickets $DONE/$TOT merged"
      fi
      if has_breakdown "$D" && [ -s "$D/tickets.json" ] && [ "$S" != closed ]; then
        SPK="$(jq -r --slurpfile t "$D/tickets.json" '[.tickets[] | select(.spike // false) | .key as $k | (($t[0][] | select(.key==$k) | .pt) // $k) + " " + .title] | join("; ")' "$D/breakdown.json" 2>/dev/null)"
        [ -n "$SPK" ] && LINE="$LINE, on Tom: $SPK$(jq -r '[.tickets[] | select(.spike // false) | .needs_from_owner[]?] | if length>0 then " (needs: " + join("; ") + ")" else "" end' "$D/breakdown.json" 2>/dev/null)"
      fi
      [ -s "$D/mr.json" ] && LINE="$LINE, MR !$(jq -r .iid "$D/mr.json")$( [ -s "$D/mr-check.json" ] && echo " (pipeline $(jq -r .pipeline "$D/mr-check.json"), $(jq -r .unresolved "$D/mr-check.json") open threads$( [ -f "$D/review-approved" ] && echo ", review clean"))")"
      spec_ready "$D" && LINE="$LINE — $(jq -r .title "$D/spec.json" | cut -c1-60)"
      echo "$LINE"
    done
    [ "$FOUND" = 0 ] && echo "No active dispatches, dearie."
    exit 0
    ;;

  tick)
    [ "${1:-}" = "--announce" ] && export MARGIE_ANNOUNCE=1
    for D in "$MDIR"/d-*; do
      [ -d "$D" ] || continue
      S="$(st "$D")"
      if [ -f "$D/replan-pending" ] && [ "$("$DIR/claude-task.sh" state "spec:$(basename "$D")")" != "RUNNING" ] \
         && [ $(( $(date +%s) - $(cat "$D/planner-started" 2>/dev/null || echo 0) )) -ge 1200 ]; then
        [ -s "$D/spec.json" ] && cp "$D/spec.json" "$D/prev-spec.json"; rm -f "$D/spec.json" "$D/spec.md" "$D/body.md" "$D/breakdown.json" "$D/breakdown.md" "$D/breakdown-running"  # a re-plan invalidates the ticket breakdown
        launch_planner "$D" "$(dmeta "$D" repo)${SUBDIR:+/$SUBDIR}" "$(cat "$D/request.txt")" 2>/dev/null || true
        st "$D" spec-running; S="spec-running"
        announce "Re-planning \"$(head -c 60 "$D/request.txt")…\" with the queued context, dearie."
      fi
      SUBDIR="$(dmeta "$D" subdir)"
      case "$S" in
        spec-ready|spec-running)
          if [ -f "$D/breakdown-running" ]; then
            if has_breakdown "$D"; then
              rm -f "$D/breakdown-running"; render_breakdown "$D"
              [ -s "$D/draft-page.id" ] && "$DIR/notion.sh" page append "$(cat "$D/draft-page.id")" --md "$D/breakdown.md" >/dev/null 2>&1
              announce "Ticket breakdown ready for \"$(jq -r .title "$D/spec.json")\", dearie — $(jq -r '.tickets|length' "$D/breakdown.json") tickets: $(jq -r '.tickets|map(.key + " " + .title)|join("; ")' "$D/breakdown.json"). $(jq -r .summary_spoken "$D/breakdown.json") It's on the draft page too."
            elif [ "$("$DIR/claude-task.sh" state "breakdown:$(basename "$D")")" = "FAILED" ]; then
              rm -f "$D/breakdown-running"; announce "The ticket breakdown for $(basename "$D") failed, dearie."
            fi
          fi
          [ "$(st "$D")" = spec-ready ] && continue
          if spec_ready "$D"; then
            st "$D" spec-ready
            publish_draft "$D"
            announce "The spec for \"$(jq -r .title "$D/spec.json")\" is ready, dearie — $(jq '.acceptance_criteria|length' "$D/spec.json") criteria, $(jq '.test_cases|length' "$D/spec.json") tests, $(jq -r .security.risk_label "$D/spec.json").$( [ -s "$D/draft-page.url" ] && echo " The draft is in Notion." )"
            # Small MRs by default: a Large/XL spec is split into tickets right away.
            case "$(jq -r '.estimate // ""' "$D/spec.json")" in L|XL)
              "$0" breakdown "$(basename "$D")" >/dev/null 2>&1 && announce "It's a big one ($(jq -r .estimate "$D/spec.json")), so I'm splitting it into tickets for smaller MRs — the list follows in a few minutes." ;;
            esac
          elif [ "$("$DIR/claude-task.sh" state "spec:$(basename "$D")")" = "FAILED" ]; then
            st "$D" spec-failed
            announce "The spec run for $(basename "$D") failed, dearie."
          fi ;;
        qa-running)
          if [ -s "$D/qa.json" ] && jq -e .verdict "$D/qa.json" >/dev/null 2>&1; then
            PT="$(jq -r .pt "$D/ticket.json")"
            V="$(jq -r .verdict "$D/qa.json")"
            { echo "## QA report ($(date -u +%F)) — verdict: $V"
              jq -r '.acceptance[] | "- [" + (if .status=="pass" then "x" else " " end) + "] " + .criterion + " — " + .status + ": " + .evidence' "$D/qa.json"
              jq -r '"\nTests: " + ((.tests | map(.status) | group_by(.) | map((.[0]) + " ×" + (length|tostring)) | join(", ")) // "none") + "\nRun: " + .test_run.command + " — " + .test_run.summary' "$D/qa.json"
              jq -r 'if (.adr_findings // []) | length > 0 then "\nADR findings:\n" + (.adr_findings | map("- " + .adr + " (" + .severity + "): " + .finding) | join("\n")) else "" end' "$D/qa.json"
            } > "$D/qa.md"
            jq -r '.mr.title + "\n\n" + .mr.description_markdown' "$D/qa.json" > "$D/mr.md"
            # Test-case row statuses (best effort; ids from tcmap by matching title)
            jq -r '.tests[]? | [.title, .status] | @tsv' "$D/qa.json" | while IFS="$(printf '\t')" read -r t tcst; do
              tcid="$(jq -r --arg t "$t" '.[$t] // empty' "$D/tcmap.json" 2>/dev/null)"
              [ -n "$tcid" ] && "$DIR/notion.sh" testcase status "$tcid" "$tcst" >/dev/null 2>&1
            done
            "$DIR/notion.sh" ticket append "$PT" --md "$D/qa.md" >/dev/null 2>&1
            DOCMD="$(jq -r '.documentation_markdown // ""' "$D/qa.json")"
            if [ -n "$DOCMD" ] && [ -s "$D/docs-page.url" ]; then
              printf '%s' "$DOCMD" > "$D/docs.md"
              "$DIR/notion.sh" page append "$(cat "$D/docs-page.url")" --md "$D/docs.md" >/dev/null 2>&1
            fi
            if [ "$V" = "pass" ]; then
              status_all "$D" "In Review"
              st "$D" qa-pass
            else
              status_all "$D" "Needs Attention"
              st "$D" qa-fail
            fi
            announce "QA on $PT: $(jq -r .summary_spoken "$D/qa.json")"
          elif [ "$("$DIR/claude-task.sh" state "qa:$(basename "$D")")" = "FAILED" ]; then
            st "$D" qa-failed-to-run
            announce "The QA run on $(jq -r '.pt // empty' "$D/ticket.json" 2>/dev/null) failed to complete, dearie."
          fi ;;
        qa-fail)
          # Hand the findings back to the coding session once; it fixes and re-signals.
          if [ -s "$D/impl.json" ] && [ ! -f "$D/qa-fail-sent" ]; then
            BR="$(jq -r .branch "$D/impl.json")"; PT="$(jq -r .pt "$D/ticket.json")"
            touch "$D/qa-fail-sent"; rm -f "$D/qa-auto"
            MSG="QA verification FAILED for $PT. Findings: $(jq -r '[.acceptance[] | select(.status!="pass") | .criterion + " — " + .status + ": " + .evidence] | join(" | ")' "$D/qa.json" | cut -c1-1500). Fix these, keep the tests green, commit, then print MARGIE_READY_FOR_QA on its own line again."
            "$DIR/session.sh" send "$MSG" --branch "$BR" >/dev/null 2>&1 && { st "$D" implementing; mv "$D/qa.json" "$D/qa-failed-$(date +%H%M).json"; announce "QA failed on $PT — I've sent the findings back into the session to fix, dearie."; }
          fi ;;
        implementing|qa-pass)
          if [ -s "$D/impl.json" ]; then
            BR="$(jq -r .branch "$D/impl.json")"; WT="$(jq -r .worktree "$D/impl.json")"
            PT="$(jq -r .pt "$D/ticket.json")"
            SCREEN="$("$DIR/session.sh" read 80 --branch "$BR" 2>/dev/null || true)"
            # Coding session signalled completion (or clearly finished and stopped) -> run QA once.
            if [ "$S" = implementing ] && [ ! -s "$D/qa.json" ] && [ ! -f "$D/qa-auto" ] && [ -n "$SCREEN" ]; then
              if printf '%s' "$SCREEN" | grep -q "MARGIE_READY_FOR_QA" \
                 || { printf '%s' "$SCREEN" | grep -qE "· done [0-9]" && ! printf '%s' "$SCREEN" | grep -q "esc to interrupt" \
                      && printf '%s' "$SCREEN" | grep -qiE "ready for QA|tests? (are|is) (complete|green|passing)|(work|implementation) (is|and tests are) complete"; }; then
                touch "$D/qa-auto"; rm -f "$D/qa-fail-sent"
                "$0" qa "$(basename "$D")" >/dev/null 2>&1 && announce "Coding on $PT reports done — running QA now, dearie." && S=qa-running
              fi
            fi
            # QA passed -> tell the session to open the MR (once); the merge closes it.
            if [ "$S" = qa-pass ] && [ ! -f "$D/mr-nudged" ]; then
              touch "$D/mr-nudged"
              if printf '%s' "$SCREEN" | grep -qE "MR !?[0-9]+|MARGIE_MR_OPEN"; then
                announce "QA passed on $PT and the session already has an MR open — MR text at $D/mr.md if it needs updating (mr.sh update), dearie."
              else
                "$DIR/session.sh" send "QA passed — open the MR now with the repo's /merge-request skill, using the prepared description at $D/mr.md (title on the first line). When it's open print MARGIE_MR_OPEN <url>." --branch "$BR" >/dev/null 2>&1 \
                  && announce "QA passed on $PT — I've told the session to open the MR, dearie."
              fi
            fi
            # ── MR lifecycle (after QA passed): detect the MR, self-review it, watch the
            # pipeline, send fixes back to the session, report "ready to merge".
            if [ "$S" = qa-pass ]; then
              if [ ! -s "$D/mr.json" ]; then
                IID="$(cd "$WT" 2>/dev/null && glab mr list --source-branch "$BR" -F json 2>/dev/null | jq -r '.[0].iid // empty')"
                if [ -n "$IID" ]; then
                  (cd "$WT" && glab mr view "$IID" -F json 2>/dev/null | jq -c '{iid, url: .web_url, title}') > "$D/mr.json"
                  announce "MR !$IID is open for $PT ($(jq -r .url "$D/mr.json")). I'll review it and watch the pipeline, dearie."
                fi
              fi
              if [ -s "$D/mr.json" ]; then
                IID="$(jq -r .iid "$D/mr.json")"
                CHK="$("$DIR/mr.sh" check "!$IID" --repo "$WT" 2>/dev/null || true)"; [ -n "$CHK" ] && printf '%s' "$CHK" > "$D/mr-check.json"
                if [ -s "$D/mr-check.json" ]; then
                SHA="$(jq -r '.sha // ""' "$D/mr-check.json" 2>/dev/null)"; PSTAT="$(jq -r '.pipeline // "none"' "$D/mr-check.json" 2>/dev/null)"; PID="$(jq -r '.pipeline_id // ""' "$D/mr-check.json" 2>/dev/null)"
                # self-review once per commit, at most 3 rounds
                UNRES="$(jq -r '.unresolved // 0' "$D/mr-check.json")"
                # Review cadence: a round runs when the MR first settles, then again only after the
                # session has cleared every open thread — never per commit (that looped the bots).
                if [ -n "$SHA" ] && [ "$(cat "$D/review-sha" 2>/dev/null)" != "$SHA" ] && [ ! -f "$D/review-running" ] && [ "$UNRES" = 0 ] \
                   && [ "$(cat "$D/review-rounds" 2>/dev/null || echo 0)" -lt "$(cfgd review_rounds 2)" ]; then
                  P="$(cat "$DIR/prompts/mr-review.md")"; P="${P//'{{MR}}'/$IID}"; P="${P//'{{PT}}'/$PT}"; P="${P//'{{TARGET}}'/$(cfgd mr_target_branch main)}"; P="${P//'{{SPEC}}'/$(spec_text "$D")$(process_notes "$D")}"
                  SUBDIR="$(dmeta "$D" subdir)"; MODEL_OPT=(); M="$(cfg qa_model)"; [ -n "$M" ] && MODEL_OPT=(--model "$M")
                  rm -f "$D/review.json"
                  if "$DIR/claude-task.sh" start "$WT${SUBDIR:+/$SUBDIR}" "$P" --deny "Edit,Write,NotebookEdit" --no-subagents --schema "$DIR/schemas/review.schema.json" \
                       --effort "$(cfgd qa_effort medium)" --budget "$(cfgd dispatch_budget_usd 4)" --tag "review:$(basename "$D")" --out "$D/review.json" ${MODEL_OPT[@]+"${MODEL_OPT[@]}"} >/dev/null 2>&1; then
                    echo "$SHA" > "$D/review-sha"; touch "$D/review-running"; echo $(( $(cat "$D/review-rounds" 2>/dev/null || echo 0) + 1 )) > "$D/review-rounds"
                  fi
                fi
                if [ -f "$D/review-running" ] && [ -s "$D/review.json" ] && jq -e .verdict "$D/review.json" >/dev/null 2>&1; then
                  rm -f "$D/review-running"; RV="$(jq -r .verdict "$D/review.json")"
                  if [ "$RV" = approve ]; then
                    touch "$D/review-approved"; announce "Reviewed MR !$IID for $PT: $(jq -r .summary_spoken "$D/review.json")"
                  else
                    rm -f "$D/review-approved"
                    FND="$(jq -r '[.findings[] | select(.severity=="blocker" or .severity=="major") | .severity + " " + .file + (if .line then ":" + (.line|tostring) else "" end) + " — " + .issue + " → " + .fix] | join(" | ")' "$D/review.json" | cut -c1-1800)"
                    "$DIR/session.sh" send "Review of MR !$IID requested changes: $FND. Address each one, keep tests green, commit and push to the MR, then print MARGIE_MR_UPDATED and STOP — do not poll the pipeline, Margie watches it." --branch "$BR" >/dev/null 2>&1
                    announce "Review of MR !$IID for $PT asked for changes — I've sent them into the session to fix, dearie: $(jq -r .summary_spoken "$D/review.json")"
                  fi
                  cp "$D/review.json" "$D/review-$(date +%H%M).json"
                elif [ -f "$D/review-running" ] && [ "$("$DIR/claude-task.sh" state "review:$(basename "$D")")" = FAILED ]; then
                  rm -f "$D/review-running"; announce "My review run on MR !$IID failed to complete, dearie — I'll retry on the next commit."
                fi
                # The repo's review bots run by themselves on the MR's first pipeline — Margie does
                # not request reviews. One fallback only: the MR has settled, more than one pipeline
                # ran (so the auto-run may have stood down) and the bots have posted nothing at all.
                if [ ! -f "$D/bots-fallback" ] && [ "$PSTAT" != running ] && [ "$PSTAT" != pending ] \
                   && [ "$(jq -r '.bot_notes // 0' "$D/mr-check.json")" = 0 ] && [ "$(jq -r '.pipelines // 0' "$D/mr-check.json")" -gt 1 ] \
                   && [ $(( $(date +%s) - $(stat -f %m "$D/mr.json") )) -gt 900 ]; then
                  touch "$D/bots-fallback"
                  RR="$("$DIR/mr.sh" request-review "!$IID" --repo "$WT" 2>/dev/null || true)"
                  case "$RR" in Requested*) announce "The repo's review bots never ran on MR !$IID for $PT (a second pipeline pre-empted them), so I asked them once, dearie." ;; esac
                fi
                # pipeline failed -> once per pipeline, send it back
                if [ "$PSTAT" = failed ] && [ -n "$PID" ] && [ "$(cat "$D/pipeline-failed" 2>/dev/null)" != "$PID" ]; then
                  echo "$PID" > "$D/pipeline-failed"
                  "$DIR/session.sh" send "The MR pipeline failed: $(jq -r .pipeline_url "$D/mr-check.json"). Read the failing job logs (glab ci view / glab api), fix the cause, commit and push, then print MARGIE_MR_UPDATED and STOP — Margie watches the pipeline." --branch "$BR" >/dev/null 2>&1
                  announce "Pipeline failed on MR !$IID for $PT — I've sent it back to the session to fix, dearie."
                fi
                # ready to merge -> tell Tom once per commit; merging is his word (dispatch.sh merge)
                REVIEW_OK=0; { [ -f "$D/review-approved" ] || [ "$(cat "$D/review-rounds" 2>/dev/null || echo 0)" -ge "$(cfgd review_rounds 2)" ]; } && REVIEW_OK=1
                if [ "$PSTAT" = success ] && [ "$UNRES" = 0 ] && [ "$(jq -r .conflicts "$D/mr-check.json")" = false ] && [ "$REVIEW_OK" = 1 ] && [ "$(cat "$D/merge-ready" 2>/dev/null)" != "$SHA" ]; then
                  echo "$SHA" > "$D/merge-ready"
                  # Tom's explicit instruction (2026-09-03): a green MR with every thread resolved is
                  # merged by Margie herself (config auto_merge, default true); no "say merge" step.
                  if [ "$(cfgd auto_merge true)" = true ]; then
                    MOUT="$("$0" merge "$(basename "$D")" 2>&1 | tail -1)"
                    case "$MOUT" in
                      Merged*) announce "MR !$IID for $PT was green with every thread resolved, so I merged it, dearie.$(printf '%s' "$MOUT" | grep -q 'Auto-merge enabled' && echo ' The merge train will land it.')" ;;
                      *) announce "MR !$IID for $PT is ready but the merge didn't go through, dearie: $MOUT" ;;
                    esac
                  else
                    announce "MR !$IID for $PT is ready to merge, dearie — pipeline green, every review thread resolved$( [ -f "$D/review-approved" ] && echo ", my review clean" || echo " (review rounds used up; the findings were addressed in the threads)"). Say \"merge\" and I'll merge it."
                  fi
                elif [ "$UNRES" != 0 ] && [ $(( $(date +%s) - $(cat "$D/threads-told-at" 2>/dev/null || echo 0) )) -gt 900 ]; then
                  # once per fix cycle (15 min), not once per thread-count change
                  date +%s > "$D/threads-told-at"
                  "$DIR/session.sh" send "MR !$IID has $UNRES unresolved review thread(s). Use the repo's /address-mr-reviews skill to address them, push, and resolve the threads you fixed; then print MARGIE_MR_UPDATED and STOP — do not poll the pipeline, Margie watches it and will tell you if anything fails." --branch "$BR" >/dev/null 2>&1
                  announce "MR !$IID for $PT has $UNRES review thread(s) — the session is addressing them, dearie."
                fi
                fi  # mr-check.json
              fi
            fi
            # Merge detection: MR for the branch merged -> ticket Done, dispatch closed.
            if [ -d "$WT" ]; then
              MRSTATE="$(cd "$WT" && glab mr view "$BR" -F json 2>/dev/null | jq -r '.state // empty')"
              if [ "$MRSTATE" = "merged" ]; then
                PT="$(jq -r .pt "$D/ticket.json")"
                status_all "$D" "Done"
                st "$D" closed
                announce "$PT merged and closed, dearie."
                # a child finished → start the next ticket, or close the umbrella after the last
                if [ -s "$D/parent" ]; then
                  PD="$MDIR/$(cat "$D/parent")"
                  if [ -d "$PD" ]; then
                    K="$(next_child "$PD")"
                    if [ -n "$K" ]; then announce "Next ticket for $(jq -r .pt "$PD/ticket.json"): $K — starting it now, dearie."; start_child "$PD" "$K" >/dev/null 2>&1
                    else
                      "$DIR/notion.sh" ticket status "$(jq -r .pt "$PD/ticket.json")" "Done" >/dev/null 2>&1; st "$PD" closed
                      announce "All tickets under $(jq -r .pt "$PD/ticket.json") are merged — umbrella closed, dearie.$( SP="$(jq -r '[.tickets[] | select(.spike // false) | .key] | join(", ")' "$PD/breakdown.json")"; [ -n "$SP" ] && echo " Still on you: $SP.")"
                    fi
                  fi
                fi
              fi
            fi
          fi ;;
      esac
    done
    exit 0
    ;;

  open)
    need_d "${1:-latest}"
    WHAT="${2:-spec}"
    F="$D/$WHAT.md"; [ -f "$F" ] || F="$D/spec.md"
    [ -f "$F" ] || { echo "Nothing to open yet, dearie." >&2; exit 1; }
    "$DIR/warp-run.sh" "$D" "less -R '$F'" | tail -1
    ;;

  close)
    need_d "${1:-latest}"
    PT="$(jq -r '.pt // empty' "$D/ticket.json" 2>/dev/null)"
    desc "would cancel ${PT:-this dispatch}'s ticket and close the dispatch"
    [ -n "$PT" ] && { status_all "$D" "Canceled"; echo "$PT canceled$( [ -s "$D/tickets.json" ] && echo " with its child tickets")."; }
    st "$D" closed
    echo "Dispatch closed, dearie."
    ;;

  replan)
    # Re-run the planner on the current request (no new context) — e.g. after a launch failure.
    need_d "${1:-latest}"
    while [ "$("$DIR/claude-task.sh" state "spec:$(basename "$D")")" != "NONE" ]; do
      "$DIR/claude-task.sh" detach "spec:$(basename "$D")" >/dev/null 2>&1 || break
    done
    [ -s "$D/spec.json" ] && cp "$D/spec.json" "$D/prev-spec.json"; rm -f "$D/spec.json" "$D/spec.md" "$D/body.md" "$D/breakdown.json" "$D/breakdown.md" "$D/breakdown-running"  # a re-plan invalidates the ticket breakdown
    REPO="$(dmeta "$D" repo)"; SUBDIR="$(dmeta "$D" subdir)"; WORKDIR="$REPO${SUBDIR:+/$SUBDIR}"
    launch_planner "$D" "$WORKDIR" "$(cat "$D/request.txt")"
    st "$D" spec-running
    echo "Re-planning '$(basename "$D")' from the current request, dearie — a few minutes." ;;
  merge)
    need_d "${1:-latest}"
    [ -s "$D/mr.json" ] || { echo "No MR on this dispatch yet, dearie." >&2; exit 1; }
    IID="$(jq -r .iid "$D/mr.json")"; WT="$(jq -r .worktree "$D/impl.json")"; PT="$(jq -r .pt "$D/ticket.json")"
    CHK="$("$DIR/mr.sh" check "!$IID" --repo "$WT" 2>/dev/null || true)"
    if [ -n "$CHK" ] && [ "${MARGIE_DESCRIBE:-0}" != 1 ]; then
      P="$(jq -r .pipeline <<<"$CHK")"; U="$(jq -r .unresolved <<<"$CHK")"
      { [ "$P" != success ] || [ "$U" != 0 ]; } && { echo "Not merging !$IID yet, dearie — pipeline is $P and $U review thread(s) are open."; exit 1; }
    fi
    "$DIR/mr.sh" merge "!$IID" --repo "$WT" ;;
  __make_child)   # internal: build (not start) the child dispatch for a ticket key
    need_d "${1:-latest}"; make_child "$D" "${2:?key}" ;;
  __next_child)
    need_d "${1:-latest}"; next_child "$D" ;;
  __resolve)
    resolve_d "${1:-latest}" ;;
  describe)
    need_d "${1:-latest}"
    MARGIE_DESCRIBE=1 "$0" "${2:-go}" "$(basename "$D")"
    ;;

  *)
    echo "usage: dispatch.sh spec <repo> \"<request>\" [--subdir p] | show [id] | brief [id] | breakdown [id] | file <id> | merge <id> | implement <id> | go <id> | qa <id> [--watch] | status [id] | tick [--announce] | open <id> [spec|qa|mr] | close <id> | describe <id> <stage>" >&2
    exit 1
    ;;
esac
