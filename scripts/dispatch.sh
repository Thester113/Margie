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
cfg() { local v; v="$(jq -r ".$1 // empty" "$CFG" 2>/dev/null)"; case "$v" in op://*) v="$(op read "$v" 2>/dev/null || true)";; esac; printf "%s" "$v"; }
cfgd() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }  # cfgd <key> <default>
desc() { if [ "${MARGIE_DESCRIBE:-0}" = "1" ]; then echo "$*"; exit 0; fi; }
slug() { printf '%s' "$1" | tr '\n\r\t' '   ' | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-28 | sed -E 's/-+$//'; }
st() { # st <dir> [new-state]
  if [ $# -gt 1 ]; then printf '%s' "$2" > "$1/state"; else cat "$1/state" 2>/dev/null || echo "unknown"; fi
}
dmeta() { jq -r ".$2 // empty" "$1/d.json" 2>/dev/null; }
# is_ui_change <worktree> <repo-name> — 0 if this branch's diff touches a UI path
# (config ui_review_paths[<repo>], e.g. ["mobile/"]); 1 otherwise. Backend-only
# MRs return 1 so they never trigger the simulator visual-review gate.
is_ui_change() {
  local wt="$1" repo="$2" pats f
  [ "$(cfgd ui_review true)" = true ] || return 1
  pats="$(jq -r --arg r "$repo" '.ui_review_paths[$r][]? // empty' "$CFG" 2>/dev/null)"
  [ -z "$pats" ] && return 1   # no UI paths configured for this repo -> not a UI MR
  local files; files="$(git -C "$wt" diff --name-only origin/main...HEAD 2>/dev/null)"
  [ -z "$files" ] && return 1
  while IFS= read -r p; do [ -z "$p" ] && continue
    printf '%s\n' "$files" | grep -q "^$p" && return 0
  done <<EOF
$pats
EOF
  return 1
}
is_chat_change() {
  # 0 if this branch's diff touches chat/AI code (config chat_review_paths[<repo>],
  # default the AI domain). Chat MRs must be verified on the UI, not just screenshotted:
  # the sim visual-review runs the actual chat flows against the branch backend.
  local wt="$1" repo="$2" pats
  pats="$(jq -r --arg r "$repo" '.chat_review_paths[$r][]? // empty' "$CFG" 2>/dev/null)"
  [ -z "$pats" ] && pats="backend/apps/walt_ui/lib/walt_ui/ai/"
  local files; files="$(git -C "$wt" diff --name-only origin/main...HEAD 2>/dev/null)"
  [ -z "$files" ] && return 1
  while IFS= read -r p; do [ -z "$p" ] && continue
    printf '%s\n' "$files" | grep -q "^$p" && return 0
  done <<EOF
$pats
EOF
  return 1
}
approved_for() { # approved_for <dispatch dir> <sha> — the local review approved THIS commit
  local a; [ -f "$1/review-approved" ] || return 1
  a="$(cat "$1/review-approved" 2>/dev/null)"; [ -z "$a" ] && a="$(cat "$1/review-note-sha" 2>/dev/null)"
  [ -n "$2" ] && [ "$a" = "$2" ]
}
ui_shot_final() {
  # 0 when the verify session is FINISHED with this screenshot. Without this,
  # tick grabs ui-shot.png the instant it appears — PT-1354 Slacked Tom a
  # mid-run capture of the debug host's error screen, which the session then
  # overwrote with the real one a minute later.
  local d="$1" screen="$2" age
  printf '%s' "$screen" | grep -q "MARGIE_UI_SHOT" && return 0
  age=$(( $(date +%s) - $(stat -f %m "$d/ui-shot.png" 2>/dev/null || echo 0) ))
  [ "$age" -ge "$(cfgd ui_shot_settle_seconds 120)" ]
}
ui_verify_stale() {
  # 0 when a kicked visual review has produced no screenshot for too long and is
  # still worth retrying. PT-1354 sat 17h because the kick was delivered as a
  # truncated tmux paste: the marker said "kicked", so nothing ever retried and
  # the MR waited on an approval Tom was never asked for.
  local d="$1" age n
  [ -f "$d/ui-verify-kicked" ] || return 1
  [ -s "$d/ui-shot.png" ] && return 1
  age=$(((  $(date +%s) - $(stat -f %m "$d/ui-verify-kicked" 2>/dev/null || echo 0) ) / 60))
  [ "$age" -ge "$(cfgd ui_verify_retry_minutes 45)" ] || return 1
  n="$(cat "$d/ui-verify-attempts" 2>/dev/null || echo 0)"
  [ "$n" -lt "$(cfgd ui_verify_max_attempts 3)" ]
}
ui_verify_exhausted() {
  local d="$1" n
  [ -f "$d/ui-verify-kicked" ] && [ ! -s "$d/ui-shot.png" ] || return 1
  n="$(cat "$d/ui-verify-attempts" 2>/dev/null || echo 0)"
  [ "$n" -ge "$(cfgd ui_verify_max_attempts 3)" ]
}
notify_domain_owners() {
  # notify_domain_owners <worktree> <repo-name> <dispatch-dir> <PT> <MR iid> <MR url>
  # Tom's rule (2026-09-17): the person who owns a domain hears about a change in it.
  # Config `domain_owners[<repo>]`: [{domain, name, slack, paths[]}]. One Slack DM per
  # domain per dispatch (marker file), sent when the MR opens. An FYI, never a gate —
  # see ~/.margie/process/cross-domain-proceed.md.
  local wt="$1" repo="$2" d="$3" pt="$4" iid="$5" url="$6" files n
  files="$(git -C "$wt" diff --name-only origin/main...HEAD 2>/dev/null)"
  [ -z "$files" ] && return 0
  n="$(jq -r --arg r "$repo" '.domain_owners[$r] | length // 0' "$CFG" 2>/dev/null)"
  [ -z "$n" ] || [ "$n" = null ] && return 0
  local i=0
  while [ "$i" -lt "$n" ]; do
    local owner dom who slack hit=0 p
    owner="$(jq -c --arg r "$repo" --argjson i "$i" '.domain_owners[$r][$i]' "$CFG" 2>/dev/null)"
    i=$((i + 1))
    dom="$(printf '%s' "$owner" | jq -r '.domain // empty')"
    who="$(printf '%s' "$owner" | jq -r '.name // empty')"
    slack="$(printf '%s' "$owner" | jq -r '.slack // empty')"
    [ -z "$slack" ] && continue
    [ -f "$d/owner-notified-$dom" ] && continue
    for p in $(printf '%s' "$owner" | jq -r '.paths[]? // empty'); do
      printf '%s\n' "$files" | grep -q "^$p" && hit=1 && break
    done
    [ "$hit" = 1 ] || continue
    "$DIR/slack.sh" send "$slack: ${who:-there} — $pt touches $dom: $(head -1 "$d/mr.md" 2>/dev/null). MR !$iid $url. Tom asked that you're looped in on $dom changes; this is an FYI, not a gate — it'll go through review and merge on its own, so say so here if you want it done differently." >/dev/null 2>&1 &&
      touch "$d/owner-notified-$dom" &&
      announce "I let ${who:-the $dom owner} know on Slack that $pt touches $dom, dearie."
  done
  return 0
}
is_web_ui_change() {
  # 0 if this branch's diff touches WEB UI code (config web_review_paths[<repo>], e.g. the
  # Phoenix LiveView tree). Web UI changes get a BROWSER visual review (not the iOS sim) and,
  # like all UI/UX, hold for Tom's approval — they never auto-merge. Backend & mobile return 1.
  local wt="$1" repo="$2" pats
  pats="$(jq -r --arg r "$repo" '.web_review_paths[$r][]? // empty' "$CFG" 2>/dev/null)"
  [ -z "$pats" ] && return 1
  local files; files="$(git -C "$wt" diff --name-only origin/main...HEAD 2>/dev/null)"
  [ -z "$files" ] && return 1
  while IFS= read -r p; do [ -z "$p" ] && continue
    printf '%s\n' "$files" | grep -q "^$p" && return 0
  done <<EOF
$pats
EOF
  return 1
}
web_review_url() {
  # The exact local URL a web-UI change should be VERIFIED at, so Margie puts eyes on the same
  # rendered page Tom does. Config: web_app_url (base, e.g. http://localhost:4000) + per-repo
  # web_review_routes [{match: <path prefix in the diff>, route: </path>}]. Prints the first
  # route whose match is in this branch's diff, else the base url. Company-agnostic: nothing hardcoded.
  local wt="$1" repo="$2" base files
  base="$(cfgd web_app_url "")"; [ -z "$base" ] && return 1
  files="$(git -C "$wt" diff --name-only origin/main...HEAD 2>/dev/null)"
  local n route match; n="$(jq -r --arg r "$repo" '.web_review_routes[$r] | length? // 0' "$CFG" 2>/dev/null)"
  local i=0
  while [ "$i" -lt "${n:-0}" ]; do
    match="$(jq -r --arg r "$repo" --argjson i "$i" '.web_review_routes[$r][$i].match // empty' "$CFG" 2>/dev/null)"
    route="$(jq -r --arg r "$repo" --argjson i "$i" '.web_review_routes[$r][$i].route // empty' "$CFG" 2>/dev/null)"
    if [ -n "$match" ] && printf '%s\n' "$files" | grep -q "$match"; then echo "${base}${route}"; return 0; fi
    i=$((i+1))
  done
  echo "$base"
}
# web_review_slot_free <dispatch> <worktree> <repo> — 0 (free) if this branch may boot its web
# verification now. Mobile is always free (per-worktree sims don't collide). Web verifications
# all bind the same host port (localhost:4000), so only ONE runs at a time — a lock at
# $MDIR/web-review.lock holds the dispatch that's mid-verify. Freed when that dispatch captured
# its shot, its dir is gone, or the lock is stale (>15m, a crashed verifier).
web_review_slot_free() {
  local d="$1" wt="$2" repo="$3" lock="$MDIR/web-review.lock" hold
  is_web_ui_change "$wt" "$repo" 2>/dev/null || return 0
  hold="$(cat "$lock" 2>/dev/null)"
  [ -z "$hold" ] && return 0
  [ "$hold" = "$(basename "$d")" ] && return 0
  [ -d "$MDIR/$hold" ] || { rm -f "$lock"; return 0; }
  [ -s "$MDIR/$hold/ui-shot.png" ] && return 0
  [ -n "$(find "$lock" -mmin +15 2>/dev/null)" ] && { rm -f "$lock"; return 0; }
  return 1
}
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
# Spikes answered with `dispatch.sh spike` leave a marker; every "on Tom" line filters them
# out, so an answered spike never keeps showing as pending (Tom's accuracy rule).
resolved_spikes() { # resolved_spikes <dispatch dir> -> JSON array of ticket keys
  local d="$1" f; printf '['; for f in "$d"/spike-resolved-*; do [ -f "$f" ] && printf '"%s",' "${f##*/spike-resolved-}"; done; printf '""]'
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

# A superseded-on-amend draft is kept, renamed (plan-change history Tom wants).
supersede_draft() { # supersede_draft <dispatch dir> <label>   e.g. "Superseded 12:51"
  local d="$1" label="$2" old title
  old="$(cat "$d/draft-page.id" 2>/dev/null)"; [ -z "$old" ] && return 0
  title="$(cat "$d/draft-page.title" 2>/dev/null)"; [ -z "$title" ] && title="Draft"
  "$DIR/notion.sh" page rename "$old" "$label — ${title#Draft — }" >/dev/null 2>&1 || true
  rm -f "$d/draft-page.id" "$d/draft-page.url" "$d/draft-page.title"
}
# Once the real ticket (with its own spec page) is filed, the "Draft — …" preview
# is redundant and reads as a duplicate — archive it (Tom, 2026-09-04). The real
# ticket keeps the plan; amend history above is a separate, kept case.
archive_draft() { # archive_draft <dispatch dir>
  local d="$1" old
  old="$(cat "$d/draft-page.id" 2>/dev/null)"; [ -z "$old" ] && return 0
  "$DIR/notion.sh" page archive "$old" >/dev/null 2>&1 || true
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
  # Make the child resolvable by its own PT id (e.g. `dispatch.sh qa PT-837`).
  cpt="$(jq -r '.pt // empty' "$c/ticket.json" 2>/dev/null)"; [ -n "$cpt" ] && ln -sfn "$c" "$MDIR/$cpt"
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
  archive_draft "$c"   # the child ticket is already filed; drop its "Draft —" preview
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
    # If the request names an EXISTING ticket to work ("Fix PT-1004: …"), remember it so we
    # move that ticket through the lifecycle instead of filing a duplicate. Jev decides
    # whether the first PT mentioned is the SUBJECT of the request or only cited (in-flight
    # work, "don't duplicate PT-1412", a related ticket); it must be sure (≥0.9) either
    # way. Fails closed to the old rule: a PT in the first 64 chars is the subject.
    EXPT=""
    FIRSTPT="$(printf '%s' "$REQ" | head -c 400 | grep -oiE '\bPT-[0-9]+\b' | head -1 | tr 'a-z' 'A-Z')"
    if [ -n "$FIRSTPT" ]; then
      JV="$(printf '%s' "$REQ" | "$DIR/jev.sh" ticket "$FIRSTPT" 2>/dev/null)" || JV=""
      case "$(printf '%s' "$JV" | cut -f1)" in
        work_existing) [ "$(printf '%s' "$JV" | cut -f2 | awk '{print ($1>=0.9)}')" = 1 ] && EXPT="$FIRSTPT" ;;
        context_only)  [ "$(printf '%s' "$JV" | cut -f2 | awk '{print ($1>=0.9)}')" = 1 ] && EXPT="-" ;;
      esac
      [ -z "$EXPT" ] && EXPT="$(printf '%s' "$REQ" | head -c 64 | grep -oiE '\bPT-[0-9]+\b' | head -1 | tr 'a-z' 'A-Z')"
      [ "$EXPT" = "-" ] && EXPT=""
    fi
    [ -n "$EXPT" ] && echo "$EXPT" > "$D/existing-pt.txt"

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
        spec-failed)  WHY="$("$DIR/claude-task.sh" why "spec:$(basename "$D")" 2>/dev/null)"; echo "The spec run failed, dearie${WHY:+ — $WHY}. dispatch.sh replan $(basename "$D") runs it again." ;;
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
    # If the request named an existing ticket ("Fix PT-1004: …"), MOVE that ticket through the
    # lifecycle rather than filing a duplicate (the bug that stranded PT-1004 in Todo while its
    # duplicate PT-1009 went to Done). Only reuse when the named PT actually resolves.
    EXPT="$(cat "$D/existing-pt.txt" 2>/dev/null)"; EXROW=""
    [ -n "$EXPT" ] && EXROW="$("$DIR/notion.sh" find "$EXPT" 2>/dev/null)"
    if [ -n "$EXROW" ]; then
      EXID="$(printf '%s' "$EXROW" | grep -oiE '\[[0-9a-f]{32}\]' | tr -d '[]')"
      EXURL="$(printf '%s' "$EXROW" | grep -oiE 'https://[^ ]+' | head -1)"
      jq -cn --arg pt "$EXPT" --arg id "$EXID" --arg url "$EXURL" '{pt:$pt, id:$id, url:$url}' > "$D/ticket.json"
      echo "Reusing existing ticket $EXPT (no duplicate created), dearie: $EXURL"
    else
      OUT="$("$DIR/notion.sh" ticket create "$TITLE" --md "$D/body.md" --priority "$PRIO" --labels "$LBLS" ${UCOPT[@]+"${UCOPT[@]}"})" || exit 1
      echo "$OUT" | head -1
      printf '%s\n' "$OUT" | tail -1 > "$D/ticket.json"
    fi
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
    # The ticket now owns the plan (its own spec page). Archive the "Draft —" preview
    # so it doesn't linger as a duplicate under the Drafts parent.
    archive_draft "$D"
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
      # Only a spike that genuinely needs Tom's input (needs_from_owner) is "on Tom". A pure
      # code-investigation spike ("locate the entry point", "does X already do Y") is session
      # work — its answer emerges from the dependent implementation, so never frame it as a hold.
      OWNER_SP="$(jq -r --argjson done "$(resolved_spikes "$D")" '[.tickets[] | select((.spike // false) and (((.needs_from_owner // []) | length) > 0) and ((.key as $k | $done | index($k)) == null)) | .key + " " + .title] | join("; ")' "$D/breakdown.json")"
      SESS_SP="$(jq -r '[.tickets[] | select((.spike // false) and (((.needs_from_owner // []) | length) == 0)) | .key + " " + .title] | join("; ")' "$D/breakdown.json")"
      [ -n "$OWNER_SP" ] && echo "On you, dearie (spike needs YOUR input, not automated): $OWNER_SP."
      [ -n "$SESS_SP" ] && echo "Code-investigation spike(s) — the sessions resolve these, not you: $SESS_SP."
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
    # Nothing to verify if the branch has no commits yet — running QA here yields a
    # misleading "nothing implemented" verdict that jams the pipeline. Wait for code.
    AHEAD="$(cd "$WT" && git rev-list --count "$(cfgd mr_target_branch main)"..HEAD 2>/dev/null || echo 0)"
    if [ "${AHEAD:-0}" = 0 ]; then
      echo "No commits on $PT's branch yet, dearie — nothing to QA. The session hasn't committed the work; I'll wait for it." >&2
      st "$D" implementing; exit 0
    fi
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
      IID="$(jq -r .iid "$D/mr.json")"; WT="$(jq -r '.worktree // empty' "$D/impl.json" 2>/dev/null)"
      # Refresh the MR state LIVE so the brief is never stale between ticks.
      CHK="$("$DIR/mr.sh" check "!$IID" --repo "${WT:-$(dmeta "$D" repo)}" 2>/dev/null || true)"; [ -n "$CHK" ] && printf '%s' "$CHK" > "$D/mr-check.json"
      MST="$( [ -s "$D/mr-check.json" ] && jq -r '"state \(.state), pipeline \(.pipeline), \(.unresolved) open review thread(s)" + (if (.bot_notes // 0) > 0 then ", bots reviewed" else "" end)' "$D/mr-check.json")"
      [ "$S" = closed ] && MST="MERGED"
      echo "MR (THIS ticket's MR): !$IID — $MST — $(jq -r .url "$D/mr.json")"
      [ "$(jq -r '.unresolved // 0' "$D/mr-check.json" 2>/dev/null)" != 0 ] && echo "  → open review threads are being addressed by the coding session (mr.sh threads !$IID to see them)."
    fi
    if has_breakdown "$D"; then
      echo "Tickets:"
      jq -r --slurpfile t "$D/tickets.json" '.tickets[] | .key as $k | "  \(( $t[0][] | select(.key==$k) | .pt ) // $k)  \(.title)  [\(.size)\(if .spike then (if ((.needs_from_owner // []) | length) > 0 then ", spike — needs Tom" else ", spike — session-resolved, NOT on Tom" end) else "" end)]" + (if ((.needs_from_owner // []) | length) > 0 then "  needs from Tom: " + (.needs_from_owner | join("; ")) else "" end)' "$D/breakdown.json" 2>/dev/null
      for c in "$MDIR/$(basename "$D")--"*; do [ -d "$c" ] && echo "  ↳ $(cat "$c/key") $(st "$c")$( [ -s "$c/mr.json" ] && echo " MR !$(jq -r .iid "$c/mr.json")")"; done
    fi
    # ONLY a spike that explicitly needs owner input is "on Tom". A code-investigation spike
    # (no needs_from_owner) is session work the coding sessions resolve — never on Tom, and a
    # closed epic with no owner-needs has nothing pending.
    ONTOM="$(jq -r --argjson done "$(resolved_spikes "$D")" '[.tickets[]? | select((.spike // false) and (((.needs_from_owner // []) | length) > 0) and ((.key as $k | $done | index($k)) == null)) | .title + " (needs: " + (.needs_from_owner | join("; ")) + ")"] | join(" | ")' "$D/breakdown.json" 2>/dev/null)"
    ANSWERED="$(jq -r --argjson done "$(resolved_spikes "$D")" '[.tickets[]? | select((.spike // false) and ((.key as $k | $done | index($k)) != null)) | .title] | join("; ")' "$D/breakdown.json" 2>/dev/null)"
    [ -n "$ANSWERED" ] && echo "Spikes answered (see the ticket notes): $ANSWERED"
    [ -n "$ONTOM" ] && [ "$S" != closed ] && echo "On Tom: $ONTOM"
    [ -n "$ONTOM" ] && [ "$S" = closed ] && echo "Still on Tom after the merge: $ONTOM"
    [ -z "$ONTOM" ] && [ "$S" = closed ] && echo "On Tom: nothing — this epic is closed, all tickets merged, no owner action needed (any spikes were code-investigation, resolved in-session)."
    for f in "$HOME/.margie/projects"/*.md; do [ -f "$f" ] || continue
      for w in $(printf '%s' "$T" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' ' ' | tr ' ' '\n' | awk 'length>3' | head -6); do
        grep -qi -- "$w" "$f" && { echo "Project note ($(basename "$f" .md)) — the CURRENT state; trust it over older ticket text:"; sed 's/^/  /' "$f" | head -90; break; }; done; done 2>/dev/null
    echo "Assumptions the spec made (say if any is wrong; nothing is being asked):"
    jq -r '.open_questions[]? | "  - " + (.[0:220])' "$D/spec.json" 2>/dev/null | head -8
    echo "Next:"
    case "$S" in
      spec-running) echo "  planner is drafting the spec" ;;
      spec-ready) echo "  $( has_breakdown "$D" && echo 'say "go" to file the Epic + tickets and start ticket 1' || echo 'say "go" to file the ticket and start the session' )" ;;
      filed|implementing) echo "  coding session in progress; QA and the MR follow automatically" ;;
      qa-running) echo "  QA verifier running" ;; qa-pass) echo "  MR under review; merge is automatic when green with all threads resolved" ;;
      qa-fail) echo "  findings sent back to the session" ;;
      closed) echo "  merged and done$( [ -n "$ONTOM" ] && echo " — only the human items above remain" || echo " — nothing pending, nothing on Tom" )" ;;
      *) echo "  $S" ;;
    esac
    ;;
  review)
    # dispatch.sh review <id|PT> — force a fresh local review round on the MR's current
    # commit, for when a verdict is stale (the fix wasn't a commit, or context changed).
    need_d "${1:?usage: dispatch.sh review <id|PT>}"
    [ -s "$D/mr.json" ] || { echo "No MR tracked for that dispatch yet, dearie." >&2; exit 1; }
    rm -f "$D/review-sha" "$D/review-running"
    echo "Fresh review queued for MR !$(jq -r .iid "$D/mr.json"), dearie — it runs on the next tick."
    ;;
  child)
    # dispatch.sh child <epic id|PT> <key…>  — start specific tickets of a broken-down
    # epic NOW, instead of waiting for each to merge before the next begins. Tom's call
    # when a few tickets decide whether something is demoable (2026-09-18). Conflicts
    # between siblings touching the same files are the price; they rebase like any MR.
    need_d "${1:?usage: dispatch.sh child <epic id|PT> <ticket key…>}"; shift
    [ -s "$D/breakdown.json" ] || { echo "That dispatch has no ticket breakdown, dearie." >&2; exit 1; }
    for KEY in "$@"; do
      jq -e --arg k "$KEY" '.tickets[] | select(.key == $k)' "$D/breakdown.json" >/dev/null 2>&1 \
        || { echo "No ticket '$KEY' in $(basename "$D"), dearie." >&2; continue; }
      if [ -d "$(child_dir "$D" "$KEY")" ]; then echo "$KEY is already started, dearie."; continue; fi
      start_child "$D" "$KEY"
    done
    ;;
  pause)
    printf '%s\n' "${1:-paused by Tom $(date -u +%FT%TZ)}" > "$HOME/.margie/paused"
    echo "Paused, dearie — tick advances nothing until you say resume."
    ;;
  resume)
    rm -f "$HOME/.margie/paused"
    echo "Resumed, dearie — the pipeline picks up on the next tick."
    ;;
  status)
    [ -f "$HOME/.margie/paused" ] && echo "PAUSED: $(head -1 "$HOME/.margie/paused")"
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
        # Enumerate the REMAINING (not-yet-merged) impl tickets with their state, so the
        # brain can never call an in-flight ticket "the last one" or assume the epic is done.
        REM=""
        while IFS=$'\t' read -r k pt; do
          [ -z "$k" ] && continue
          cdir="$MDIR/$(basename "$D")--$k"
          if [ -d "$cdir" ]; then cst="$(st "$cdir")"; else cst="not started"; fi
          [ "$cst" = closed ] && continue
          REM="$REM, $pt $k=$cst"
        done < <(jq -r --slurpfile t "$D/tickets.json" '.tickets[] | select((.spike // false)|not) | .key as $k | ($k + "\t" + (($t[0][]|select(.key==$k)|.pt)//$k))' "$D/breakdown.json" 2>/dev/null)
        [ -n "$REM" ] && LINE="$LINE; remaining${REM}" || LINE="$LINE; none remaining"
      fi
      if has_breakdown "$D" && [ -s "$D/tickets.json" ] && [ "$S" != closed ]; then
        SPK="$(jq -r --slurpfile t "$D/tickets.json" --argjson done "$(resolved_spikes "$D")" '[.tickets[] | select((.spike // false) and ((.key as $k | $done | index($k)) == null)) | .key as $k | (($t[0][] | select(.key==$k) | .pt) // $k) + " " + .title] | join("; ")' "$D/breakdown.json" 2>/dev/null)"
        SPKNEEDS="$(jq -r --argjson done "$(resolved_spikes "$D")" '[.tickets[] | select((.spike // false) and ((.key as $k | $done | index($k)) == null)) | .needs_from_owner[]?] | join("; ")' "$D/breakdown.json" 2>/dev/null)"
        if [ -n "$SPK" ]; then
          # A spike is engineering investigation the coding session resolves itself —
          # only "on Tom" when it explicitly lists needs_from_owner (a real human decision).
          if [ -n "$SPKNEEDS" ]; then LINE="$LINE, on Tom: $SPK (needs: $SPKNEEDS)"
          else LINE="$LINE, spike (session-resolved, NOT a blocker/not on Tom): $SPK"; fi
        fi
      fi
      if [ -s "$D/mr.json" ]; then
        # State the merge disposition explicitly so the brain never guesses "auto-merges":
        # a UI/UX change holds for Tom's approval; a backend change auto-merges when green.
        MRNOTE=""
        if [ -s "$D/impl.json" ]; then
          MWT="$(jq -r .worktree "$D/impl.json" 2>/dev/null)"; MREPO="$(basename "$(dmeta "$D" repo)")"
          if is_web_ui_change "$MWT" "$MREPO" 2>/dev/null; then MRNOTE=" — WEB UI: HOLDS for Tom's approval (browser verify), will NOT auto-merge"
          elif is_ui_change "$MWT" "$MREPO" 2>/dev/null; then MRNOTE=" — MOBILE UI: HOLDS for Tom's approval (sim verify), will NOT auto-merge"
          elif is_chat_change "$MWT" "$MREPO" 2>/dev/null; then MRNOTE=" — CHAT change: HOLDS for Tom's approval (sim chat-flow verify), will NOT auto-merge"
          else MRNOTE=" — backend: auto-merges when green + review-approved"; fi
        fi
        # A hold outranks everything above: never report "auto-merges" for an MR that is
        # held (PT-1353's NAT MRs read "auto-merges when green" while held for Johnny).
        [ -f "$D/hold-merge" ] && MRNOTE=" — HELD: $(head -1 "$D/hold-merge" | cut -c1-140)"
        LINE="$LINE, MR !$(jq -r .iid "$D/mr.json")$( [ -s "$D/mr-check.json" ] && echo " (pipeline $(jq -r .pipeline "$D/mr-check.json"), $(jq -r .unresolved "$D/mr-check.json") open threads$( if approved_for "$D" "$(jq -r '.sha // ""' "$D/mr-check.json")"; then echo ", review clean"; elif [ -f "$D/review-approved" ]; then echo ", review pending on the latest commit"; fi))")$MRNOTE"
      fi
      spec_ready "$D" && LINE="$LINE — $(jq -r .title "$D/spec.json" | cut -c1-60)"
      echo "$LINE"
    done
    [ "$FOUND" = 0 ] && echo "No active dispatches, dearie."
    exit 0
    ;;

  tick)
    # Global pause (Tom, 2026-09-17): while ~/.margie/paused exists, the pipeline
    # advances NOTHING — no QA, no MR, no merge, no deploy, no owner pings.
    # `dispatch.sh status` still reads. Remove the file (or `dispatch.sh resume`)
    # to start again.
    [ -f "$HOME/.margie/paused" ] && { echo "Paused: $(head -1 "$HOME/.margie/paused")"; exit 0; }
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
              rm -f "$D/breakdown-running"
              if [ ! -f "$D/breakdown-retried" ]; then   # planners occasionally miss the schema; one retry is cheap
                touch "$D/breakdown-retried"; "$0" breakdown "$(basename "$D")" >/dev/null 2>&1 && announce "The ticket breakdown for \"$(jq -r .title "$D/spec.json")\" stumbled once — retrying it, dearie."
              else announce "The ticket breakdown for \"$(jq -r .title "$D/spec.json")\" failed twice, dearie — say \"break it down\" to try again."; fi
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
            WHY="$("$DIR/claude-task.sh" why "spec:$(basename "$D")" 2>/dev/null)"
            announce "The spec run for $(basename "$D") failed, dearie${WHY:+ — $WHY}. Say \"replan\" to run it again."
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
          # Hand the findings back to the coding session; it fixes and re-signals. Archive
          # the failed report FIRST so the next MARGIE_READY_FOR_QA can trigger a fresh run
          # (a leftover qa.json used to deadlock the loop). Restart the session if it exited.
          if [ -s "$D/impl.json" ] && [ -s "$D/qa.json" ]; then
            BR="$(jq -r .branch "$D/impl.json")"; PT="$(jq -r .pt "$D/ticket.json")"; WT="$(jq -r .worktree "$D/impl.json")"
            FND="$(jq -r '[.acceptance[] | select(.status!="pass") | .criterion + " — " + .status + ": " + .evidence] | join(" | ")' "$D/qa.json" | cut -c1-1500)"
            mv "$D/qa.json" "$D/qa-failed-$(date +%H%M%S).json"; rm -f "$D/qa-auto"; st "$D" implementing
            SESS="margie-$(printf '%s' "$BR" | tr '/ ' '--')"; SUBDIR="$(dmeta "$D" subdir)"
            if tmux has-session -t "$SESS" 2>/dev/null; then
              "$DIR/session.sh" send "QA FAILED for $PT. Findings: $FND. Fix these, keep the tests green, commit, then print MARGIE_READY_FOR_QA on its own line again and stop." --branch "$BR" >/dev/null 2>&1
              announce "QA failed on $PT — I've sent the findings back into the session to fix, dearie."
            else
              P="You are back on branch $BR (ticket $PT). QA verification FAILED with these findings: $FND. Fix them, keep the tests green, commit to the branch, then print MARGIE_READY_FOR_QA on its own line and stop — Margie re-runs QA."
              "$DIR/kickoff-claude.sh" "$WT" ${SUBDIR:+--subdir "$SUBDIR"} --worktree "$BR" "$P" >/dev/null 2>&1
              announce "QA failed on $PT and its session had ended — I restarted a session to fix the findings, dearie."
            fi
          fi ;;
        implementing|qa-pass)
          if [ -s "$D/impl.json" ]; then
            BR="$(jq -r .branch "$D/impl.json")"; WT="$(jq -r .worktree "$D/impl.json")"
            PT="$(jq -r .pt "$D/ticket.json")"
            SCREEN="$("$DIR/session.sh" read 80 --branch "$BR" 2>/dev/null || true)"
            # Coding session signalled completion (or clearly finished and stopped) -> run QA once.
            if [ "$S" = implementing ] && [ ! -s "$D/qa.json" ] && [ ! -f "$D/qa-auto" ] && [ -n "$SCREEN" ]; then
              # MARGIE_READY_FOR_QA must be Claude's OWN output on its own line — NOT the
              # echoed instruction in the input box ("...print MARGIE_READY_FOR_QA...again").
              # The marker can scroll off: Claude Code keeps no scrollback (24 lines on
              # PT-1400 after its own monitors fired every 30 min for 17 h), so a session
              # that committed and said "waiting on Margie's QA" sat unseen. Second signal:
              # the session is idle, its worktree is clean and ahead of main, and its
              # screen says it handed off — by regex, or by Jev's session triage
              # (checkpoint/handoff, never question/working) when the wording is new.
              IDLE=0; printf '%s' "$SCREEN" | grep -q "esc to interrupt" || IDLE=1
              HANDED=0
              if [ "$IDLE" = 1 ] && [ -z "$(git -C "$WT" status --porcelain 2>/dev/null)" ] \
                 && [ "$(git -C "$WT" rev-list --count "origin/$(cfgd mr_target_branch main)..HEAD" 2>/dev/null || echo 0)" -gt 0 ]; then
                if printf '%s' "$SCREEN" | grep -qiE "waiting (on|for) (margie'?s )?qa|ready for qa|hand(ed)? (off|over) to qa|over to (margie|qa)"; then HANDED=1
                elif printf '%s' "$SCREEN" | grep -qE "· done [0-9]"; then
                  JK="$(printf '%s' "$SCREEN" | "$DIR/jev.sh" session 2>/dev/null | cut -f1)"
                  case "$JK" in checkpoint|handoff) HANDED=1 ;; esac
                fi
              fi
              if { printf '%s' "$SCREEN" | grep -qE '^[[:space:]]*MARGIE_READY_FOR_QA[[:space:]]*$' && [ "$IDLE" = 1 ]; } \
                 || { printf '%s' "$SCREEN" | grep -qE "· done [0-9]" && [ "$IDLE" = 1 ] \
                      && printf '%s' "$SCREEN" | grep -qiE "tests? (are|is) (complete|green|passing)|(work|implementation) (is|and tests are) complete"; } \
                 || [ "$HANDED" = 1 ]; then
                touch "$D/qa-auto"; rm -f "$D/qa-fail-sent"
                "$0" qa "$(basename "$D")" >/dev/null 2>&1 && announce "Coding on $PT reports done — running QA now, dearie." && S=qa-running
              fi
            fi
            # A session that opened its OWN MR out-of-band (didn't print MARGIE_READY_FOR_QA)
            # is also "ready" — otherwise the pipeline never adopts+reviews it and the charter
            # review never runs (the recurring "reviewer didn't go off" gap on !900 / !907).
            if [ "$S" = implementing ] && [ ! -s "$D/qa.json" ] && [ ! -f "$D/qa-auto" ]; then
              OPENMR="$(cd "$WT" 2>/dev/null && glab mr list --source-branch "$BR" -F json 2>/dev/null | jq -r '[.[] | select(.state=="opened")][0].iid // empty')"
              if [ -n "$OPENMR" ]; then
                touch "$D/qa-auto"; rm -f "$D/qa-fail-sent"
                "$0" qa "$(basename "$D")" >/dev/null 2>&1 && announce "$PT has MR !$OPENMR open (the session opened it) — running QA now so it gets reviewed, dearie." && S=qa-running
              fi
            fi
            # QA passed -> tell the session to open the MR (once); the merge closes it.
            # A failed `glab mr create` used to park the dispatch for good: the
            # marker said "nudged", no mr.json ever appeared, and nothing retried
            # (PT-1362 sat at qa-pass with its branch pushed and no MR). Retry a
            # nudge that produced no MR, a few minutes apart, then say so.
            if [ "$S" = qa-pass ] && [ -f "$D/mr-nudged" ] && [ ! -s "$D/mr.json" ] &&
               [ "$(( ( $(date +%s) - $(stat -f %m "$D/mr-nudged" 2>/dev/null || echo 0) ) / 60 ))" -ge "$(cfgd mr_open_retry_minutes 10)" ]; then
              N="$(cat "$D/mr-open-attempts" 2>/dev/null || echo 1)"
              if [ "$N" -lt "$(cfgd mr_open_max_attempts 3)" ]; then
                echo $((N + 1)) > "$D/mr-open-attempts"; rm -f "$D/mr-nudged"
                announce "The MR for $PT never opened, dearie — trying again (attempt $((N + 1)))."
              elif [ ! -f "$D/mr-open-gaveup" ]; then
                touch "$D/mr-open-gaveup"
                "$DIR/slack.sh" send "@$(cfgd owner_first_name Tom): $PT passed QA but its MR won't open after $N tries — the branch is pushed; it needs a look (mr.sh create $PT)." >/dev/null 2>&1 || true
                announce "$PT passed QA but I couldn't open its MR after $N tries, dearie — I've pinged you on Slack."
              fi
            fi
            if [ "$S" = qa-pass ] && [ ! -f "$D/mr-nudged" ]; then
              touch "$D/mr-nudged"
              [ -f "$D/mr-open-attempts" ] || echo 1 > "$D/mr-open-attempts"
              if printf '%s' "$SCREEN" | grep -qE "^[[:space:]]*MARGIE_MR_OPEN|/-/merge_requests/[0-9]+|![0-9]{2,} (opened|created)"; then
                announce "QA passed on $PT and the session already has an MR open — MR text at $D/mr.md if it needs updating (mr.sh update), dearie."
              else
                # Open the MR DETERMINISTICALLY with mr.sh (push + create from the prepared
                # mr.md) — never by queuing an instruction into a session, which used to stall.
                WT="$(jq -r .worktree "$D/impl.json")"
                ( cd "$WT" && git push -u origin "$BR" >/dev/null 2>&1 )
                TITLE="$(head -1 "$D/mr.md" 2>/dev/null)"; sed -n '2,$p' "$D/mr.md" 2>/dev/null > "$D/mr-body.md"
                MRURL="$( cd "$WT" && glab mr create --source-branch "$BR" --target-branch "$(cfgd mr_target_branch main)" --title "$TITLE" --description "$(cat "$D/mr-body.md" 2>/dev/null)" --yes 2>/dev/null | grep -oE 'https://[^ ]+/merge_requests/[0-9]+' | head -1 )"
                if [ -n "$MRURL" ]; then
                  IID="$(printf '%s' "$MRURL" | grep -oE '[0-9]+$')"
                  ( cd "$WT" && glab mr view "$IID" -F json 2>/dev/null | jq -c '{iid, url: .web_url, title}' ) > "$D/mr.json"
                  announce "QA passed on $PT — I opened MR !$IID ($MRURL), dearie. It'll go through review and merge on its own."
                  notify_domain_owners "$WT" "$(basename "$(dmeta "$D" repo)")" "$D" "$PT" "$IID" "$MRURL"
                else
                  announce "QA passed on $PT but I couldn't open the MR automatically, dearie — the branch may need a manual push. mr.sh create $PT."
                fi
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
                  notify_domain_owners "$WT" "$(basename "$(dmeta "$D" repo)")" "$D" "$PT" "$IID" "$(jq -r .url "$D/mr.json")"
                fi
              fi
              if [ -s "$D/mr.json" ]; then
                IID="$(jq -r .iid "$D/mr.json")"
                CHK="$("$DIR/mr.sh" check "!$IID" --repo "$WT" 2>/dev/null || true)"; [ -n "$CHK" ] && printf '%s' "$CHK" > "$D/mr-check.json"
                if [ -s "$D/mr-check.json" ]; then
                SHA="$(jq -r '.sha // ""' "$D/mr-check.json" 2>/dev/null)"; PSTAT="$(jq -r '.pipeline // "none"' "$D/mr-check.json" 2>/dev/null)"; PID="$(jq -r '.pipeline_id // ""' "$D/mr-check.json" 2>/dev/null)"
                # self-review once per commit, at most 3 rounds
                UNRES="$(jq -r '.unresolved // 0' "$D/mr-check.json")"
                # A fix that isn't a commit (replying to and resolving review threads, editing the
                # MR description) never earned a re-review, because reviews key on the commit sha:
                # !1154 sat on a stale 'request_changes' about Erich's threads long after every one
                # was answered (2026-09-18). When the session says MARGIE_MR_UPDATED after a
                # request_changes on this same sha, allow ONE fresh round for that sha.
                if [ -n "$SHA" ] && [ "$(cat "$D/review-sha" 2>/dev/null)" = "$SHA" ] && [ ! -f "$D/review-running" ] \
                   && [ "$(jq -r '.verdict // ""' "$D/review.json" 2>/dev/null)" = request_changes ] \
                   && [ ! -f "$D/rereviewed-$SHA" ] && printf '%s' "$SCREEN" | grep -q "MARGIE_MR_UPDATED"; then
                  touch "$D/rereviewed-$SHA"; rm -f "$D/review-sha"
                  announce "The session says it addressed the review on MR !$(jq -r .iid "$D/mr.json") without a new commit — re-reviewing it, dearie."
                fi
                # Review cadence: a round runs when the MR first settles, then again only after the
                # session has cleared every open thread — never per commit (that looped the bots).
                if [ -n "$SHA" ] && [ "$(cat "$D/review-sha" 2>/dev/null)" != "$SHA" ] && [ ! -f "$D/review-running" ] && [ "$UNRES" = 0 ]; then
                  # Re-review fires on every NEW commit (review-sha guards against re-reviewing the
                  # same sha) — no total-rounds cap, which used to deadlock: a stale round could burn
                  # the cap and freeze a request_changes verdict even after the session fixed it
                  # (the !900 gap). A fresh commit always deserves a fresh verdict, and only an actual
                  # `approve` merges (never round exhaustion). The re-review is told what the last
                  # round found and which commits were pushed since, so it VERIFIES each prior finding
                  # against the current diff instead of parroting it.
                  PRIOR=""
                  if [ -s "$D/review.json" ] && jq -e .verdict "$D/review.json" >/dev/null 2>&1; then
                    PSHA="$(cat "$D/review-sha" 2>/dev/null)"
                    PF="$(jq -r 'if (.findings|length)>0 then ([.findings[]|"- ["+(.severity//"nit")+"] "+(.file//"")+(if .line then ":"+(.line|tostring) else "" end)+" — "+(.issue//"")]|join("\n")) else "(none)" end' "$D/review.json")"
                    PRIOR="
RE-REVIEW — a prior round returned verdict '$(jq -r .verdict "$D/review.json")' with these findings:
$PF
Since then the session pushed new commit(s): run \`git log --oneline ${PSHA:+$PSHA..}HEAD\` and read them. For EACH prior finding, check the CURRENT diff and state whether it is now RESOLVED — do NOT re-raise a finding the new commits fixed (a 'missing test' finding is resolved once that test exists in the diff; verify by reading it). Report only findings that STILL hold on the current code, plus any genuinely new problems.
"
                  fi
                  P="$(cat "$DIR/prompts/mr-review.md")"; P="${P//'{{MR}}'/$IID}"; P="${P//'{{PT}}'/$PT}"; P="${P//'{{TARGET}}'/$(cfgd mr_target_branch main)}"; P="${P//'{{SPEC}}'/$(spec_text "$D")$(process_notes "$D")}"; P="${P//'{{PRIOR_REVIEW}}'/$PRIOR}"
                  # Local review charters: the repo's own reviewer subagents (config review_agents,
                  # e.g. code-reviewer/adr-reviewer) are the local stand-ins for the dead CI review
                  # bots. Apply their charters here on Tom's plan — cheaper/faster, no CI credits.
                  RAGENTS=""
                  for AG in $(jq -r '.review_agents[]? // empty' "$CFG" 2>/dev/null); do
                    AGF="$WT/.claude/agents/$AG.md"; [ -f "$AGF" ] || continue
                    RAGENTS="$RAGENTS

===== reviewer charter: $AG (local stand-in for the CI $AG bot) =====
$(awk 'c>=2; /^---$/{c++}' "$AGF")"
                  done
                  [ -n "$RAGENTS" ] && RAGENTS="
DO THE REVIEW BY APPLYING THESE REPO REVIEWER CHARTERS — the local stand-ins for the CI
review bots (same criteria, run here on Tom's plan). Work through each in turn and base your
findings on it; map their must-fix / ADR-violation findings to blocker or major, nits to nit.
Cover BOTH code review and ADR compliance.$RAGENTS
"
                  P="${P//'{{REVIEW_AGENTS}}'/$RAGENTS}"
                  SUBDIR="$(dmeta "$D" subdir)"; MODEL_OPT=(); M="$(cfg qa_model)"; [ -n "$M" ] && MODEL_OPT=(--model "$M")
                  rm -f "$D/review.json"
                  if "$DIR/claude-task.sh" start "$WT${SUBDIR:+/$SUBDIR}" "$P" --deny "Edit,Write,NotebookEdit" --no-subagents --schema "$DIR/schemas/review.schema.json" \
                       --effort "$(cfgd review_effort high)" --budget "$(cfgd dispatch_budget_usd 4)" --tag "review:$(basename "$D")" --out "$D/review.json" ${MODEL_OPT[@]+"${MODEL_OPT[@]}"} >/dev/null 2>&1; then
                    echo "$SHA" > "$D/review-sha"; touch "$D/review-running"; echo $(( $(cat "$D/review-rounds" 2>/dev/null || echo 0) + 1 )) > "$D/review-rounds"
                  fi
                fi
                # A review round that never delivers (its headless task died, the Mac slept, the
                # network dropped) used to leave `review-running` forever, so no later commit was
                # ever reviewed: !1186's rebased commit sat green and unreviewed for two hours
                # (2026-09-19). Treat a marker older than the review's own time budget as dead.
                if [ -f "$D/review-running" ] && [ ! -s "$D/review.json" ] \
                   && [ $(( ( $(date +%s) - $(stat -f %m "$D/review-running") ) / 60 )) -ge "$(cfgd review_stale_minutes 45)" ]; then
                  rm -f "$D/review-running" "$D/review-sha"
                  announce "A review round on MR !$(jq -r .iid "$D/mr.json") for $PT never came back — starting a fresh one, dearie."
                fi
                # Harvest a verdict whenever review.json is NEWER than the last one we recorded —
                # not only while the running-marker is present. A forced re-review (dispatch.sh
                # review) whose marker got cleared underneath it left an approve verdict on disk
                # that tick never read, so !1186 sat unmerged for hours (2026-09-19).
                if [ -s "$D/review.json" ] && jq -e .verdict "$D/review.json" >/dev/null 2>&1 \
                   && { [ -f "$D/review-running" ] || [ "$D/review.json" -nt "$D/review-harvested" ] 2>/dev/null || [ ! -f "$D/review-harvested" ]; }; then
                  rm -f "$D/review-running"; touch "$D/review-harvested"; RV="$(jq -r .verdict "$D/review.json")"
                  # Post the local review to the MR so it is VISIBLE on GitLab (the charter agents
                  # don't post themselves; this record replaces the CI review bots' comments, so an
                  # MR never looks "unreviewed" while a real review happened). Once per commit.
                  if [ -n "$IID" ] && [ "$(cat "$D/review-note-sha" 2>/dev/null)" != "$SHA" ]; then
                    RSUM="$(jq -r '.summary_spoken // ""' "$D/review.json")"
                    RFND="$(jq -r 'if (.findings|length)>0 then ([.findings[] | "- " + (.severity//"nit") + " " + (.file//"") + (if .line then ":"+(.line|tostring) else "" end) + " — " + (.issue//"") + (if .fix then " → " + .fix else "" end)] | join("\n")) else "No findings." end' "$D/review.json")"
                    RNOTE="$(printf '🤖 Local review (code-reviewer + adr-reviewer charters, on Margie'\''s plan; CI review bots retired) — verdict: **%s** for commit %s\n\n%s\n\n%s' "$RV" "${SHA:0:8}" "$RSUM" "$RFND")"
                    ( cd "$WT" && glab mr note create "$IID" --resolvable=false --message "$RNOTE" ) >/dev/null 2>&1 && echo "$SHA" > "$D/review-note-sha"
                  fi
                  SESS="margie-$(printf '%s' "$BR" | tr '/ ' '--')"; SUBDIR="$(dmeta "$D" subdir)"
                  if [ "$RV" = approve ]; then
                    echo "$SHA" > "$D/review-approved"; rm -f "$D/review-rejects"; announce "Reviewed MR !$IID for $PT: $(jq -r .summary_spoken "$D/review.json")"
                  else
                    rm -f "$D/review-approved"
                    FND="$(jq -r '[.findings[] | select(.severity=="blocker" or .severity=="major") | .severity + " " + .file + (if .line then ":" + (.line|tostring) else "" end) + " — " + .issue + " → " + .fix] | join(" | ")' "$D/review.json" | cut -c1-1800)"
                    [ -z "$FND" ] && FND="$(jq -r '.summary_spoken // "see the review note on the MR"' "$D/review.json")"
                    MSG="Review of MR !$IID requested changes: $FND. Address each one, keep tests green, commit and push to the MR, then print MARGIE_MR_UPDATED and STOP — do not poll the pipeline, Margie watches it."
                    # Feed the findings back — restart the session if it has exited (findings sent to a
                    # dead tmux session used to vanish, leaving the MR stuck at request_changes forever).
                    if tmux has-session -t "$SESS" 2>/dev/null; then
                      "$DIR/session.sh" send "$MSG" --branch "$BR" >/dev/null 2>&1
                      announce "Review of MR !$IID for $PT asked for changes — I've sent them into the session to fix, dearie: $(jq -r .summary_spoken "$D/review.json")"
                    else
                      "$DIR/kickoff-claude.sh" "$WT" ${SUBDIR:+--subdir "$SUBDIR"} --worktree "$BR" "You are back on branch $BR (ticket $PT). $MSG" >/dev/null 2>&1
                      announce "Review of MR !$IID for $PT asked for changes and its session had ended — I restarted a session to fix them, dearie: $(jq -r .summary_spoken "$D/review.json")"
                    fi
                    # Loop safety: after enough rejects on this MR, ping Tom once (per commit) — the
                    # fix loop keeps going, but a review that never clears may need his eyes.
                    RJ=$(( $(cat "$D/review-rejects" 2>/dev/null || echo 0) + 1 )); echo "$RJ" > "$D/review-rejects"
                    if [ "$RJ" -ge "$(cfgd review_max_rounds 4)" ] && [ "$(cat "$D/review-escalated-sha" 2>/dev/null)" != "$SHA" ]; then
                      echo "$SHA" > "$D/review-escalated-sha"
                      "$DIR/slack.sh" send "@$(cfgd owner_first_name Tom): MR !$IID ($PT) has been through $RJ review rounds and still isn't clean — the local review keeps requesting changes. It may need your eyes. $(jq -r '.url // empty' "$D/mr.json" 2>/dev/null)" >/dev/null 2>&1 || true
                      announce "Heads up, dearie: MR !$IID for $PT has had $RJ review rounds and still isn't approved — I keep sending the fixes in, but it may need your eyes. I pinged you on Slack."
                    fi
                  fi
                  cp "$D/review.json" "$D/review-$(date +%H%M).json"
                elif [ -f "$D/review-running" ] && [ "$("$DIR/claude-task.sh" state "review:$(basename "$D")")" = FAILED ]; then
                  rm -f "$D/review-running"; announce "My review run on MR !$IID failed to complete, dearie — I'll retry on the next commit."
                fi
                # The repo's review bots auto-run on the MR's first pipeline. One fallback: the MR
                # settled, the review jobs are present (reviews_seen) yet the bots posted NOTHING at
                # all — whether a later pipeline pre-empted the auto-run OR the first-pipeline auto-run
                # completed without posting (seen on mobile-only MRs) — so play the manual request once.
                if [ ! -f "$D/bots-fallback" ] && [ "$PSTAT" != running ] && [ "$PSTAT" != pending ] \
                   && [ -z "$(jq -r '.review_agents[]? // empty' "$CFG" 2>/dev/null | head -1)" ] \
                   && [ "$(jq -r '.bot_notes // 0' "$D/mr-check.json")" = 0 ] && [ "$(jq -r '.reviews_seen // false' "$D/mr-check.json")" = true ] \
                   && [ "$(jq -r '.reviews_failed // 0' "$D/mr-check.json")" = 0 ] \
                   && [ $(( $(date +%s) - $(stat -f %m "$D/mr.json") )) -gt 900 ]; then
                  touch "$D/bots-fallback"
                  RR="$("$DIR/mr.sh" request-review "!$IID" --repo "$WT" 2>/dev/null || true)"
                  case "$RR" in Requested*) announce "The repo's review bots hadn't posted on MR !$IID for $PT, so I asked them once, dearie." ;; esac
                fi
                # The review bots ERRORED (their CI jobs failed, not just slow) — re-running won't
                # help (e.g. the walt_ui CI's Anthropic "credit balance is too low"). Tell Tom once
                # per pipeline; merge stays held (BOTS_OK stays 0) because they never really reviewed.
                # Only alarm about CI review-bot failures when we're RELYING on the CI bots. With
                # local review agents configured, their CI counterparts are retired — a failed CI
                # review job is expected and Margie's own round covers the review, so stay quiet.
                if [ -z "$(jq -r '.review_agents[]? // empty' "$CFG" 2>/dev/null | head -1)" ] \
                   && [ "$(jq -r '.reviews_failed // 0' "$D/mr-check.json")" -gt 0 ] && [ "$(cat "$D/reviews-failed-pid" 2>/dev/null)" != "${PID:-x}" ]; then
                  echo "${PID:-x}" > "$D/reviews-failed-pid"
                  announce "Heads up, dearie: the review bots FAILED on MR !$IID for $PT — their CI jobs errored (not just slow), so no real review happened. This usually means the walt_ui CI's Anthropic credit balance ran out; it needs a CI fix, not a re-run. Merge is held until they pass. $(jq -r '.pipeline_url // empty' "$D/mr-check.json")"
                fi
                # pipeline failed -> once per pipeline, send it back
                if [ "$PSTAT" = failed ] && [ -n "$PID" ] && [ "$(cat "$D/pipeline-failed" 2>/dev/null)" != "$PID" ]; then
                  echo "$PID" > "$D/pipeline-failed"
                  "$DIR/session.sh" send "The MR pipeline failed: $(jq -r .pipeline_url "$D/mr-check.json"). Read the failing job logs (glab ci view / glab api), fix the cause, commit and push, then print MARGIE_MR_UPDATED and STOP — Margie watches the pipeline." --branch "$BR" >/dev/null 2>&1
                  announce "Pipeline failed on MR !$IID for $PT — I've sent it back to the session to fix, dearie."
                fi
                # ready to merge -> tell Tom once per commit; merging is his word (dispatch.sh merge)
                # Only an actual `approve` verdict merges — never round exhaustion (Tom's rule:
                # an approved local review -> merge & move to the next ticket, unless the MR is held).
                # A stuck request_changes blocks the merge until it's fixed and re-reviewed clean.
                REVIEW_OK=0; approved_for "$D" "$SHA" && REVIEW_OK=1
                # The bots must have ACTUALLY reviewed before merge — "0 open threads" is
                # trivially true before they post. Require the review bridges finished and the
                # bots posted (or none exist in this repo). This stops merging unreviewed.
                BOTS_OK=1
                if [ -n "$(jq -r '.review_agents[]? // empty' "$CFG" 2>/dev/null | head -1)" ]; then
                  # Local review mode: the charter review must have POSTED its result to the MR for
                  # THIS commit before merge — a visible review of the current code, never a stale
                  # or empty approval. (This is what stops a "no reviews" MR reaching the train.)
                  [ "$(cat "$D/review-note-sha" 2>/dev/null)" = "$SHA" ] || BOTS_OK=0
                elif [ "$(jq -r '.reviews_seen // false' "$D/mr-check.json")" = true ]; then
                  # No local agents: still gate on the CI review bots having actually posted.
                  { [ "$(jq -r '.reviews_done // false' "$D/mr-check.json")" = true ] && [ "$(jq -r '.bot_notes // 0' "$D/mr-check.json")" -gt 0 ]; } || BOTS_OK=0
                fi
                GATE_GREEN=0
                { [ "$PSTAT" = success ] && [ "$UNRES" = 0 ] && [ "$(jq -r .conflicts "$D/mr-check.json")" = false ] && [ "$REVIEW_OK" = 1 ] && [ "$BOTS_OK" = 1 ]; } && GATE_GREEN=1
                REPO_NAME="$(basename "$(dmeta "$D" repo)")"
                if [ "$GATE_GREEN" = 1 ] && { is_ui_change "$WT" "$REPO_NAME" || is_chat_change "$WT" "$REPO_NAME"; }; then
                  # Tom's rule (2026-09-03): a UI-touching MR is NEVER auto-merged. Margie boots
                  # it in the simulator, verifies it visually, shows Tom (screenshot opened on his
                  # Mac + Slack ping, sim left running) and waits for his explicit "merge". Backend
                  # MRs skip all of this (is_ui_change returns false).
                  if [ "$(cat "$D/ui-verified-sha" 2>/dev/null)" = "$SHA" ]; then
                    :   # already shown for this commit — holding for Tom's word
                  elif [ -s "$D/ui-shot.png" ] && [ "$(cat "$D/ui-verify-kicked" 2>/dev/null)" = "$SHA" ] && ui_shot_final "$D" "$SCREEN"; then
                    [ "$(cat "$MDIR/web-review.lock" 2>/dev/null)" = "$(basename "$D")" ] && rm -f "$MDIR/web-review.lock"
                    open "$D/ui-shot.png" >/dev/null 2>&1 || true
                    METHOD="in the simulator"; is_web_ui_change "$WT" "$REPO_NAME" && METHOD="in a browser"
                    UIMSG="UI MR !$IID ($PT) is green and ready — I verified it $METHOD (screenshot attached). Review it and say \"merge\" when it looks right. $(jq -r '.url // empty' "$D/mr.json" 2>/dev/null)"
                    # Upload the screenshot INTO Slack (files:write) so Tom reviews it there, not only
                    # on his Mac; fall back to a text ping if the upload fails.
                    "$DIR/slack.sh" upload "$D/ui-shot.png" --to "@$(cfgd owner_first_name Tom)" --comment "$UIMSG" >/dev/null 2>&1 \
                      || "$DIR/slack.sh" send "@$(cfgd owner_first_name Tom): $UIMSG (screenshot is open on your Mac.)" >/dev/null 2>&1 || true
                    echo "$SHA" > "$D/ui-verified-sha"
                    announce "MR !$IID for $PT is a UI/UX change, dearie — I verified it $METHOD and captured a screenshot (open on your Mac, and I pinged you on Slack). I won't merge a UI/UX change without your eyes: say \"merge\" when it looks right."
                  elif { [ "$(cat "$D/ui-verify-kicked" 2>/dev/null)" != "$SHA" ] || ui_verify_stale "$D"; } && web_review_slot_free "$D" "$WT" "$REPO_NAME"; then
                    if [ "$(cat "$D/ui-verify-kicked" 2>/dev/null)" = "$SHA" ]; then
                      echo $(( $(cat "$D/ui-verify-attempts" 2>/dev/null || echo 0) + 1 )) > "$D/ui-verify-attempts"
                    else
                      echo 1 > "$D/ui-verify-attempts"; rm -f "$D/ui-verify-gaveup"
                    fi
                    echo "$SHA" > "$D/ui-verify-kicked"; rm -f "$D/ui-shot.png"
                    if is_web_ui_change "$WT" "$REPO_NAME"; then
                      echo "$(basename "$D")" > "$MDIR/web-review.lock"
                      # This verifier holds the single web-review slot, so it OWNS localhost:4000.
                      # Free the port first: stop any other compose app publishing host 4000 (a
                      # leftover localdev or a prior verify) so this branch's app can bind it — the
                      # #1 cause of a web verify silently opening the wrong app or getting bumped.
                      for c in $(docker ps --format '{{.ID}}\t{{.Ports}}' 2>/dev/null | grep -E ':4000->4000' | cut -f1); do docker stop "$c" >/dev/null 2>&1; done
                    fi
                    SESS="margie-$(printf '%s' "$BR" | tr '/ ' '--')"; SUBDIR="$(dmeta "$D" subdir)"
                    if is_web_ui_change "$WT" "$REPO_NAME"; then
                      # WEB UI/UX (Phoenix LiveView / app.heyamby.ai): verify in a BROWSER, not the
                      # iOS sim. Like all UI/UX it never auto-merges — it holds for Tom's approval.
                      # Verify at the EXACT rendered page (config web_app_url + web_review_routes),
                      # e.g. an integrations change -> http://localhost:4000/settings/integrations,
                      # so Margie has eyes on the same page Tom does (Tom's rule 2026-09-14).
                      TURL="$(web_review_url "$WT" "$REPO_NAME" 2>/dev/null)"
                      VP="VISUAL REVIEW ONLY (ticket $PT, branch $BR) — this is a WEB UI change (Phoenix LiveView / app.heyamby.ai), so verify it in a BROWSER, not the simulator. You are a VERIFIER, not the implementer: READ-ONLY. Do NOT edit, refactor, commit, push, or modify the MR — make NO production-code change. Steps: (1) get the dev web app running ON THIS BRANCH and open ${TURL:-the exact page this MR changes} in a real browser (a headless Chrome via the debug port, or the repo's Wallaby/Playwright helpers). To bring the local app up if it isn't: in \$(the backend dir) build the walt_ui assets (mix esbuild app && mix tailwind app — the umbrella 'mix assets.build' also builds marketing and can fail on it, that's fine), ensure docker-compose.override.yml publishes the app port, docker compose up -d app, then mix ecto.migrate (a pull usually adds migrations); read the app LOGS if a request 500/503s — they name the cause. (2) You MAY make TEMPORARY local-only tweaks to reach the screen — seed a demo tenant/user with the required capability (connection.manage) and the FUB/Brevo connections the page shows — but REVERT every such edit (git checkout) before you finish and never commit them. (3) Navigate to ${TURL:-the changed page} and ACTUALLY LOOK at the rendered UI: is the layout right, aligned, styled, nothing overflowing/overlapping/unstyled/broken, and does THIS ticket's change appear and work? (4) Capture the screenshot to \"$D/ui-shot.png\". (5) In your final message, give a short UI ASSESSMENT for Tom — call out anything that looks bad or broken (even though the merge still holds for his approval, not yours); do NOT edit it. (6) print MARGIE_UI_SHOT $D/ui-shot.png on its own line and STOP with the worktree clean. If you genuinely cannot boot the app or capture the screenshot, say exactly why — do NOT fake a pass; the merge stays held for Tom's review either way. (7) After the screenshot, bring the local app DOWN to free port 4000 for the next web verification: in the backend dir run 'docker compose stop app' (or 'docker compose down'). Do not loop."
                    else
                    # Allocate a DEDICATED per-worktree simulator (a clone of the base device) so
                    # parallel mobile verifications never collide on one shared sim.
                    SIMDEV="$("$DIR/sim.sh" device-for "$BR" 2>/dev/null)"
                    VP="VISUAL REVIEW ONLY (ticket $PT, branch $BR). You are a VERIFIER, not the implementer: this is a READ-ONLY screenshot task. Do NOT edit, refactor, rework, improve, commit, push, or open/modify the MR — even if you think the code is wrong. Make NO production-code change. This branch has its OWN dedicated simulator${SIMDEV:+ (device $SIMDEV)} so it never collides with other parallel runs — pass ${SIMDEV:+--device $SIMDEV }to every sim.sh command. Steps: (1) boot and run this branch in the iOS simulator: sim.sh run \"$WT\"${SUBDIR:+ --subdir $SUBDIR}${SIMDEV:+ --device $SIMDEV} ; (2) to make THIS ticket's UI visible you MAY make TEMPORARY local-only tweaks — seed demo data, force the feature flag on (demo mode + Firebase Remote Config) — but REVERT every such edit (git checkout) before you finish, and never commit them; (3) navigate to the exact screen this MR changes (use sim.sh scroll${SIMDEV:+ --device $SIMDEV} / sim.sh tap${SIMDEV:+ --device $SIMDEV}); (4) capture it: sim.sh shot${SIMDEV:+ --device $SIMDEV} --out \"$D/ui-shot.png\" ; (5) if the screen looks wrong or you believe code needs changing, do NOT change it — say so in your final message for Tom to decide; (6) print MARGIE_UI_SHOT $D/ui-shot.png on its own line and STOP, leaving the sim running and the worktree clean. If you cannot reach the exact screen, screenshot the closest relevant one and say which. NOTE on EXTERNAL-APP launches: if this ticket's action opens native Messages/Phone/Mail/Maps via an sms:/smsto:/tel:/mailto: URL, the iOS Simulator CAN show it — Messages/Phone/Mail do open in the sim. Capture the RESULT: fire the exact launch URL with \`xcrun simctl openurl ${SIMDEV:-booted} \"<the url>\"\` (or tap the button), then sim.sh shot${SIMDEV:+ --device $SIMDEV} — a group sms: URL opens a native New Message with both recipients in To:. Screenshot that composer, not just the button. Only if the sim genuinely cannot render it, screenshot the button's screen and note the launch URL is covered by the widget test. Do not loop."
                    if is_chat_change "$WT" "$REPO_NAME"; then
                      VP="$VP  ADDITIONAL - THIS MR CHANGES CHAT CODE, so a screenshot of an unchanged screen is NOT enough; you MUST verify the chat behavior ON THE UI against THIS BRANCH's backend: (a) start the branch backend and seed contacts that have Move Scores - in $WT/backend bring up the docker app (bin/docker-setup, or docker compose --env-file .env --env-file .env.secrets up -d app) and seed a few scored contacts; (b) point the simulator app at that backend (Profile -> Set debug URL, or the debug base-url SharedPreference); (c) in Amby Chat run the flagship flows this change affects - at minimum 'Rank my database - which 10% should I focus on right now?' (top-N by Move Score) AND a task-decline flow ('Add a task to follow up with <one of the contacts>'); (d) confirm in the RENDERED result that every contact shows as a CARD and NO raw id leaks: pipe the rendered chat text through chat-leak-scan.sh (it fails on any (id:)/uuid) and eyeball the screen; (e) sim.sh shot${SIMDEV:+ --device $SIMDEV} --out \"$D/ui-shot.png\" of the chat result. If ANY raw id appears or the flow errors, the fix is NOT verified - say so plainly for Tom and do NOT present it as working. Revert any temporary seed/URL tweaks (git checkout) before finishing."
                    fi
                    fi
                    # The visual-review prompt is long; handing it to a session as one giant tmux
                    # paste gets TRUNCATED (the session then sees only the tail — e.g. "step 7" with
                    # steps 1-6 missing, so it never boots/screenshots). Write it to a file and give
                    # the session a SHORT pointer to READ it — delivered intact every time.
                    printf '%s\n' "$VP" > "$D/verify-prompt.txt"
                    VPMSG="VISUAL REVIEW for ticket $PT (branch $BR): read the file $D/verify-prompt.txt and follow ALL of its steps exactly, then STOP. It is a READ-ONLY screenshot task — do not edit, commit, or push."
                    if tmux has-session -t "$SESS" 2>/dev/null; then "$DIR/session.sh" send "$VPMSG" --branch "$BR" >/dev/null 2>&1
                    else "$DIR/kickoff-claude.sh" "$WT" ${SUBDIR:+--subdir "$SUBDIR"} --worktree "$BR" "$VPMSG" >/dev/null 2>&1; fi
                    if is_web_ui_change "$WT" "$REPO_NAME"; then
                      announce "MR !$IID for $PT is a web UI/UX change - verifying it in a browser before any merge, dearie (it won't auto-merge; it holds for your approval)."
                    else
                      announce "MR !$IID for $PT touches the UI - booting it in the simulator to verify visually before any merge, dearie."
                    fi
                  elif ui_verify_exhausted "$D" && [ ! -f "$D/ui-verify-gaveup" ]; then
                    # Retries spent and still no screenshot: tell Tom rather than sit silently.
                    touch "$D/ui-verify-gaveup"
                    "$DIR/slack.sh" send "@$(cfgd owner_first_name Tom): MR !$IID ($PT) is green and mergeable, but I couldn't capture the UI screenshot after $(cat "$D/ui-verify-attempts" 2>/dev/null || echo several) tries — it's holding for your eyes WITHOUT one. $(jq -r '.url // empty' "$D/mr.json" 2>/dev/null)" >/dev/null 2>&1 || true
                    announce "I couldn't get a screenshot of MR !$IID for $PT after several tries, dearie — it's green and held for you, and I've said so on Slack."
                  fi
                elif [ "$GATE_GREEN" = 1 ] && [ "$(cat "$D/merge-ready" 2>/dev/null)" != "$SHA" ]; then
                  echo "$SHA" > "$D/merge-ready"
                  # Tom's explicit instruction (2026-09-03): a green MR with every thread resolved is
                  # merged by Margie herself (config auto_merge, default true); no "say merge" step.
                  if [ "$(cfgd auto_merge true)" = true ] && [ ! -f "$D/hold-merge" ]; then
                    MOUT="$("$0" merge "$(basename "$D")" 2>&1 | tail -1)"
                    case "$MOUT" in
                      Merged*)
                        DEP=""
                        case "$MOUT" in
                          *"deploy to prod"*) DEP=" It'll deploy to prod." ;;
                          *"NOT auto-deploying"*) DEP=" It's High Risk, so it won't auto-deploy — say the word to ship it." ;;
                          *"won't auto-deploy"*) DEP=" Heads up: it merged but I couldn't add the deploy label, so it won't ship on its own." ;;
                        esac
                        announce "MR !$IID for $PT was green with every thread resolved, so I merged it, dearie.$DEP$(printf '%s' "$MOUT" | grep -q 'Auto-merge enabled' && echo ' The merge train will land it.')" ;;
                      *) announce "MR !$IID for $PT is ready but the merge didn't go through, dearie: $MOUT" ;;
                    esac
                  else
                    announce "MR !$IID for $PT is ready to merge, dearie — pipeline green, every review thread resolved, my review clean.$( [ -f "$D/hold-merge" ] && echo " It's held: $(cat "$D/hold-merge")." ) Say \"merge\" and I'll merge it."
                  fi
                elif [ "$UNRES" != 0 ]; then
                  # See the MR through to approval: keep a coding session working on the open
                  # review threads (bot or human) until none remain. Restart the session if it
                  # has exited; nudge it (throttled) if it is still alive.
                  SESS="margie-$(printf '%s' "$BR" | tr '/ ' '--')"
                  THREADS="$("$DIR/mr.sh" threads "!$IID" --repo "$WT" 2>/dev/null | head -20)"
                  if ! tmux has-session -t "$SESS" 2>/dev/null; then
                    if [ "$(cat "$D/threads-restart-sha" 2>/dev/null)" != "$SHA:$UNRES" ]; then
                      echo "$SHA:$UNRES" > "$D/threads-restart-sha"; date +%s > "$D/threads-told-at"
                      SUBDIR="$(dmeta "$D" subdir)"
                      P="You are back on branch $BR (ticket $PT). MR !$IID has $UNRES unresolved review thread(s) from the review bots/reviewers that MUST be resolved before it can merge:
$THREADS
Address every one with the repo's /address-mr-reviews skill: fix the code, keep the tests green, commit, push to the MR, and RESOLVE each thread you fixed. When all threads are resolved print MARGIE_MR_UPDATED and stop — Margie watches the pipeline."
                      "$DIR/kickoff-claude.sh" "$WT" ${SUBDIR:+--subdir "$SUBDIR"} --worktree "$BR" "$P" >/dev/null 2>&1
                      announce "MR !$IID for $PT has $UNRES open review thread(s) and its session had ended — I restarted a session to address them, dearie."
                    fi
                  elif [ $(( $(date +%s) - $(cat "$D/threads-told-at" 2>/dev/null || echo 0) )) -gt 900 ]; then
                    date +%s > "$D/threads-told-at"
                    "$DIR/session.sh" send "MR !$IID still has $UNRES unresolved review thread(s): $THREADS  Address each with /address-mr-reviews, push, resolve the threads you fixed, then print MARGIE_MR_UPDATED and stop." --branch "$BR" >/dev/null 2>&1
                    announce "MR !$IID for $PT has $UNRES review thread(s) — the session is addressing them, dearie."
                  fi
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
                # Retire the coding session — its ticket is merged, nothing left to do.
                tmux kill-session -t "margie-$(printf '%s' "$BR" | tr '/ ' '--')" 2>/dev/null || true
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

  spike)
    # Answer a spike that was "on Tom": notes onto its ticket, ticket Done, marker so no
    # status line lists it as pending again. The next child session reads the ticket page,
    # so the answer reaches the coder without a follow-up.
    #   dispatch.sh spike <epic id|PT> <ticket key|PT> --md <file> | "<answer>"
    need_d "${1:?usage: dispatch.sh spike <epic id|PT> <T-key|PT> --md <file> | \"<answer>\"}"; shift
    has_breakdown "$D" || { echo "That dispatch has no ticket breakdown, dearie." >&2; exit 1; }
    WHICH="${1:?ticket key or PT}"; shift
    KEY="$(jq -r --arg w "$WHICH" '.[] | select(.key==$w or .pt==$w) | .key' "$D/tickets.json" | head -1)"
    PT="$(jq -r --arg w "$WHICH" '.[] | select(.key==$w or .pt==$w) | .pt' "$D/tickets.json" | head -1)"
    [ -n "$KEY" ] && [ -n "$PT" ] || { echo "No ticket $WHICH on this epic, dearie." >&2; exit 1; }
    jq -e --arg k "$KEY" '.tickets[] | select(.key==$k) | .spike // false' "$D/breakdown.json" >/dev/null 2>&1 || { echo "$PT is not a spike, dearie — its answer goes into its session." >&2; exit 1; }
    MD=""; ANS=""
    while [ $# -gt 0 ]; do case "$1" in --md) MD="${2:-}"; shift 2 ;; *) ANS="${ANS:+$ANS }$1"; shift ;; esac; done
    if [ -z "$MD" ]; then
      [ -n "$ANS" ] || { echo "Give the answer: --md <file> or \"<text>\"." >&2; exit 1; }
      MD="$(mktemp)"; printf '## Spike answer (%s)\n%s\n' "$(date -u +%F)" "$ANS" > "$MD"
    fi
    desc "would append the spike answer to $PT, set it Done, and stop listing it as on Tom"
    "$DIR/notion.sh" ticket append "$PT" --md "$MD" >/dev/null || exit 1
    "$DIR/notion.sh" ticket status "$PT" Done >/dev/null || exit 1
    touch "$D/spike-resolved-$KEY"
    echo "$PT answered and Done, dearie — it is off your plate; the child sessions read it from the ticket." ;;
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
    echo "usage: dispatch.sh spec <repo> \"<request>\" [--subdir p] | show [id] | brief [id] | breakdown [id] | file <id> | merge <id> | implement <id> | go <id> | qa <id> [--watch] | status [id] | tick [--announce] | open <id> [spec|qa|mr] | close <id> | spike <id> <T|PT> --md f|\"answer\" | describe <id> <stage>" >&2
    exit 1
    ;;
esac
