#!/bin/bash
# dispatch.sh — Margie's product→architecture→QA dispatch pipeline.
#
# One dispatch = one feature request, thought through by a headless Claude Code
# planner IN the target repo, filed as a Notion ticket (+ test cases + spec
# page), implemented in a watchable Warp session on its own worktree branch,
# verified by a headless QA pass, and closed when the MR merges.
#
#   dispatch.sh spec <repo> "<request>" [--subdir backend]   start the planner (minutes)
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
desc() { if [ "${MARGIE_DESCRIBE:-0}" = "1" ]; then echo "$*"; exit 0; fi; }
slug() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-28; }
st() { # st <dir> [new-state]
  if [ $# -gt 1 ]; then printf '%s' "$2" > "$1/state"; else cat "$1/state" 2>/dev/null || echo "unknown"; fi
}
dmeta() { jq -r ".$2 // empty" "$1/d.json" 2>/dev/null; }
resolve_d() { # id | PT-### | latest | fuzzy word -> dispatch dir (follows the PT symlink)
  local x="${1:-latest}" p m
  [ "$x" = "latest" ] && { ls -td "$MDIR"/d-* 2>/dev/null | head -1; return; }
  p="$MDIR/$x"
  [ -e "$p" ] && { cd "$p" 2>/dev/null && pwd -P; return; }
  # Fuzzy: newest dispatch whose id or spec title mentions the word ("healthz").
  m="$(ls -td "$MDIR"/d-* 2>/dev/null | grep -i -- "$(printf '%s' "$x" | tr 'A-Z ' 'a-z-')" | head -1)"
  [ -n "$m" ] && { echo "$m"; return; }
  for p in $(ls -td "$MDIR"/d-* 2>/dev/null); do
    jq -re --arg x "$x" '.title | ascii_downcase | contains($x | ascii_downcase)' "$p/spec.json" >/dev/null 2>&1 && { echo "$p"; return; }
  done
  echo ""
}
need_d() {
  D="$(resolve_d "${1:-latest}")"
  [ -n "$D" ] && [ -d "$D" ] || { echo "No such dispatch${1:+ '$1'}, sir." >&2; exit 1; }
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
    [ -d "$WORKDIR" ] || { echo "No such directory $WORKDIR, sir." >&2; exit 1; }
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

    CASE_TYPES="$("$DIR/notion.sh" schema testcases 2>/dev/null | awk -F'  +' '$1=="Case Type"{print $3}')"
    [ -z "$CASE_TYPES" ] && CASE_TYPES="ExUnit.Case|DataCase|ConnCase|Property-based|CommonTest"
    LABELS="$("$DIR/notion.sh" schema tickets 2>/dev/null | awk -F'  +' '$1=="Labels"{print $3}')"
    [ -z "$LABELS" ] && LABELS="Claude"

    P="$(cat "$DIR/prompts/spec-planner.md")"
    P="${P//'{{REQUEST}}'/$REQ}"
    P="${P//'{{CONTEXT}}'/$(cat "$D/context.md")}"
    P="${P//'{{CASE_TYPES}}'/$CASE_TYPES}"
    P="${P//'{{LABELS}}'/$LABELS}"
    printf '%s' "$P" > "$D/planner-prompt.txt"

    MODEL_OPT=(); M="$(cfg planner_model)"; [ -n "$M" ] && MODEL_OPT=(--model "$M")
    "$DIR/claude-task.sh" start "$WORKDIR" "$(cat "$D/planner-prompt.txt")" \
      --plan --schema "$DIR/schemas/spec.schema.json" \
      --allow "mcp__claude_ai_Notion__notion-fetch,mcp__claude_ai_Notion__notion-search,mcp__claude_ai_Notion__notion-query-data-sources" \
      --tag "spec:$ID" --out "$D/spec.json" ${MODEL_OPT[@]+"${MODEL_OPT[@]}"} > /dev/null
    st "$D" spec-running
    echo "Drafting the spec for '$ID' in $(basename "$REPO")${SUBDIR:+/$SUBDIR}, sir — product, architecture and QA. A few minutes; check with: dispatch.sh show"
    ;;

  show)
    need_d "${1:-latest}"
    if ! spec_ready "$D"; then
      case "$(st "$D")" in
        spec-running) echo "The spec is still being drafted, sir." ;;
        spec-failed)  echo "The spec run failed, sir — see claude-task.sh log." ;;
        *) echo "No spec on this dispatch yet, sir." ;;
      esac
      exit 0
    fi
    jq -r '
      "Spec: " + .title + " (" + .estimate + ", " + .security.risk_label + ")",
      "Goal: " + .goal,
      "Story: " + .use_case.story,
      ("Scope: " + ((.scope | length | tostring)) + " items, " + ((.acceptance_criteria | length | tostring)) + " acceptance criteria, " + ((.test_cases | length | tostring)) + " test cases"),
      (if (.open_questions | length) > 0 then "Open questions: " + (.open_questions | join(" | ")) else "No open questions." end),
      "Say \"go\" to file the ticket and start Claude, sir."
    ' "$D/spec.json"
    ;;

  file)
    need_d "${1:-latest}"
    spec_ready "$D" || { echo "The spec isn't ready yet, sir." >&2; exit 1; }
    TITLE="$(jq -r .title "$D/spec.json")"
    NTC="$(jq '.test_cases | length' "$D/spec.json")"
    RISK="$(jq -r .security.risk_label "$D/spec.json")"
    desc "would file Notion ticket \"$TITLE\" ($NTC test cases, $RISK) plus a spec page, in the Tickets database"
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
    "$DIR/notion.sh" testcase add "$PT" --json "$D/testcases.json" | { read -r line1; echo "$line1"; cat > "$D/tcmap.json"; }
    DOCS="$("$DIR/notion.sh" page create "$PT — Spec & QA plan" --md "$D/spec.md" --parent "$TID")" && echo "$DOCS"
    printf '%s' "$DOCS" | grep -oE 'https://[^ ]+' | head -1 > "$D/docs-page.url" || true
    ln -sfn "$D" "$MDIR/$PT"
    st "$D" filed
    echo "Filed $PT, sir: $TURL"
    ;;

  implement)
    need_d "${1:-latest}"
    [ -s "$D/ticket.json" ] || { echo "File the ticket first, sir (dispatch.sh file)." >&2; exit 1; }
    PT="$(jq -r .pt "$D/ticket.json")"; TURL="$(jq -r .url "$D/ticket.json")"
    REPO="$(dmeta "$D" repo)"; SUBDIR="$(dmeta "$D" subdir)"
    BRANCH="$(cfg branch_prefix)"; BRANCH="${BRANCH:-margie}/$PT-$(jq -r .slug "$D/spec.json")"
    P="$(cat "$DIR/prompts/implement.md")"
    P="${P//'{{PT}}'/$PT}"
    P="${P//'{{TICKET_URL}}'/$TURL}"
    P="${P//'{{BRANCH}}'/$BRANCH}"
    P="${P//'{{MR_FILE}}'/$D/mr.md}"
    P="${P//'{{SPEC}}'/$(cat "$D/spec.md")}"
    KOUT="$("$DIR/kickoff-claude.sh" "$REPO" --worktree "$BRANCH" ${SUBDIR:+--subdir "$SUBDIR"} "$P")" || exit 1
    echo "$KOUT" | tail -1
    WT="$HOME/.margie/worktrees/$(basename "$REPO")__$(printf '%s' "$BRANCH" | tr '/ ' '--')"
    jq -n --arg branch "$BRANCH" --arg wt "$WT" '{branch:$branch, worktree:$wt}' > "$D/impl.json"
    "$DIR/notion.sh" ticket status "$PT" "In Progress" >/dev/null && echo "$PT is In Progress."
    st "$D" implementing
    ;;

  go)
    need_d "${1:-latest}"
    spec_ready "$D" || { echo "The spec isn't ready yet, sir." >&2; exit 1; }
    TITLE="$(jq -r .title "$D/spec.json")"
    desc "would file Notion ticket \"$TITLE\" with $(jq '.test_cases|length' "$D/spec.json") test cases and a spec page, then start a Claude Code session on branch $(cfg branch_prefix | grep . || echo margie)/PT-…-$(jq -r .slug "$D/spec.json") in a worktree"
    "$0" file "$(basename "$D")" && "$0" implement "$(basename "$D")"
    ;;

  qa)
    WATCH=0; ARGS=()
    for a in "$@"; do case "$a" in --watch) WATCH=1 ;; *) ARGS+=("$a") ;; esac; done
    need_d "${ARGS[0]:-latest}"
    [ -s "$D/impl.json" ] || { echo "Nothing implemented to verify on this dispatch, sir." >&2; exit 1; }
    PT="$(jq -r .pt "$D/ticket.json")"; TURL="$(jq -r .url "$D/ticket.json")"
    WT="$(jq -r .worktree "$D/impl.json")"; SUBDIR="$(dmeta "$D" subdir)"
    [ -d "$WT" ] || { echo "The worktree is gone, sir ($WT)." >&2; exit 1; }
    P="$(cat "$DIR/prompts/qa-verifier.md")"
    P="${P//'{{PT}}'/$PT}"
    P="${P//'{{TICKET_URL}}'/$TURL}"
    P="${P//'{{SPEC}}'/$(cat "$D/spec.md")}"
    if [ "$WATCH" = 1 ]; then
      "$DIR/kickoff-claude.sh" "$WT" ${SUBDIR:+--subdir "$SUBDIR"} "$P" | tail -1
    else
      MODEL_OPT=(); M="$(cfg qa_model)"; [ -n "$M" ] && MODEL_OPT=(--model "$M")
      "$DIR/claude-task.sh" start "$WT${SUBDIR:+/$SUBDIR}" "$P" \
        --deny "Edit,Write,NotebookEdit" --schema "$DIR/schemas/qa.schema.json" \
        --tag "qa:$(basename "$D")" --out "$D/qa.json" ${MODEL_OPT[@]+"${MODEL_OPT[@]}"} > /dev/null
      st "$D" qa-running
      echo "QA verification is running on $PT, sir — I'll report the verdict."
    fi
    ;;

  status)
    if [ -n "${1:-}" ]; then DIRS="$(resolve_d "$1")"; else DIRS="$(ls -td "$MDIR"/d-* 2>/dev/null)"; fi
    [ -z "$DIRS" ] && { echo "No dispatches, sir."; exit 0; }
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
      spec_ready "$D" && LINE="$LINE — $(jq -r .title "$D/spec.json" | cut -c1-60)"
      echo "$LINE"
    done
    [ "$FOUND" = 0 ] && echo "No active dispatches, sir."
    exit 0
    ;;

  tick)
    [ "${1:-}" = "--announce" ] && export MARGIE_ANNOUNCE=1
    for D in "$MDIR"/d-*; do
      [ -d "$D" ] || continue
      S="$(st "$D")"
      case "$S" in
        spec-running)
          if spec_ready "$D"; then
            st "$D" spec-ready
            announce "The spec for \"$(jq -r .title "$D/spec.json")\" is ready, sir — $(jq '.acceptance_criteria|length' "$D/spec.json") criteria, $(jq '.test_cases|length' "$D/spec.json") tests, $(jq -r .security.risk_label "$D/spec.json")."
          elif [ "$("$DIR/claude-task.sh" state "spec:$(basename "$D")")" = "FAILED" ]; then
            st "$D" spec-failed
            announce "The spec run for $(basename "$D") failed, sir."
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
              "$DIR/notion.sh" ticket status "$PT" "In Review" >/dev/null 2>&1
              st "$D" qa-pass
            else
              "$DIR/notion.sh" ticket status "$PT" "Needs Attention" >/dev/null 2>&1
              st "$D" qa-fail
            fi
            announce "QA on $PT: $(jq -r .summary_spoken "$D/qa.json")"
          elif [ "$("$DIR/claude-task.sh" state "qa:$(basename "$D")")" = "FAILED" ]; then
            st "$D" qa-failed-to-run
            announce "The QA run on $(jq -r '.pt // empty' "$D/ticket.json" 2>/dev/null) failed to complete, sir."
          fi ;;
        implementing|qa-pass)
          # Merge detection: MR for the branch merged -> ticket Done, dispatch closed.
          if [ -s "$D/impl.json" ]; then
            BR="$(jq -r .branch "$D/impl.json")"; WT="$(jq -r .worktree "$D/impl.json")"
            if [ -d "$WT" ]; then
              MRSTATE="$(cd "$WT" && glab mr view "$BR" -F json 2>/dev/null | jq -r '.state // empty')"
              if [ "$MRSTATE" = "merged" ]; then
                PT="$(jq -r .pt "$D/ticket.json")"
                "$DIR/notion.sh" ticket status "$PT" "Done" >/dev/null 2>&1
                st "$D" closed
                announce "$PT merged and closed, sir."
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
    [ -f "$F" ] || { echo "Nothing to open yet, sir." >&2; exit 1; }
    "$DIR/warp-run.sh" "$D" "less -R '$F'" | tail -1
    ;;

  close)
    need_d "${1:-latest}"
    PT="$(jq -r '.pt // empty' "$D/ticket.json" 2>/dev/null)"
    desc "would cancel ${PT:-this dispatch}'s ticket and close the dispatch"
    [ -n "$PT" ] && "$DIR/notion.sh" ticket status "$PT" "Canceled" | tail -1
    st "$D" closed
    echo "Dispatch closed, sir."
    ;;

  describe)
    need_d "${1:-latest}"
    MARGIE_DESCRIBE=1 "$0" "${2:-go}" "$(basename "$D")"
    ;;

  *)
    echo "usage: dispatch.sh spec <repo> \"<request>\" [--subdir p] | show [id] | file <id> | implement <id> | go <id> | qa <id> [--watch] | status [id] | tick [--announce] | open <id> [spec|qa|mr] | close <id> | describe <id> <stage>" >&2
    exit 1
    ;;
esac
