#!/bin/bash
# mr.sh — Margie authors merge requests (GitLab; GitHub PRs via forge=github).
#
#   mr.sh draft  <PT|dispatch|--branch <b> [--repo <r>]>   title + description she would use
#   mr.sh create <PT|dispatch|--branch <b> [--repo <r>]> [--draft] [--target <branch>]
#                                          [held] push the branch, open the MR, link the ticket
#   mr.sh update <PT|!n> [--title <t>] [--description-file <f>]      [held]
#   mr.sh view   <PT|!n> [repo]                read-only (forge.sh mr)
#   mr.sh check  <PT|!n> [--repo r]            one JSON line: state, pipeline, unresolved, approvals, sha
#   mr.sh merge  <PT|!n> [--repo r]            merge it (held; the session's branch is removed)
#   mr.sh request-review <PT|!n> [--repo r]    play the manual review-bot jobs on the MR's latest pipeline
#
# The description is the repo's own MR template, fully filled, ending with the
# one `/label ~"… Risk"` quick action the release job requires. For a dispatch
# that has been QA'd, the verifier's draft (mr.md / qa.json) is used; otherwise
# a headless Claude run in the worktree drafts one (detached — `create` asks you
# to try again in a minute if the draft isn't ready). DRY_RUN=1 prints the glab
# command instead of running it. MARGIE_DESCRIBE=1 describes without acting.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CFG="$HOME/.margie/config.json"
cfg() { jq -r ".$1 // empty" "$CFG" 2>/dev/null; }
desc() { if [ "${MARGIE_DESCRIBE:-0}" = "1" ]; then echo "$*"; exit 0; fi; }
MDIR="$HOME/.margie/dispatch"; MRDIR="$HOME/.margie/mr"; mkdir -p "$MRDIR"
FORGE="$(cfg forge)"; FORGE="${FORGE:-github}"
TARGET_DEFAULT="$(cfg mr_target_branch)"; TARGET_DEFAULT="${TARGET_DEFAULT:-main}"
slug() { printf '%s' "$1" | tr 'A-Z/ ' 'a-z--' | tr -cd 'a-z0-9-'; }

cmd="${1:-draft}"; shift || true
BRANCH_OF_D=""
REF=""; BRANCH=""; REPO_ARG=""; DRAFT=0; TARGET="$TARGET_DEFAULT"; TITLE_OPT=""; DESC_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --repo) REPO_ARG="${2:-}"; shift 2 ;;
    --draft) DRAFT=1; shift ;;
    --target) TARGET="${2:-main}"; shift 2 ;;
    --title) TITLE_OPT="${2:-}"; shift 2 ;;
    --description-file) DESC_FILE="${2:-}"; shift 2 ;;
    --*) echo "Unknown option '$1', dearie. Usage: mr.sh draft|create <PT|dispatch|--branch b [--repo r]> [--draft] [--target b] | update <PT|!n> [--title t] [--description-file f]" >&2; exit 1 ;;
    *) [ -z "$REF" ] && REF="$1" || REF="$REF $1"; shift ;;
  esac
done

# ── Resolve what we're opening an MR for ─────────────────────────────────────
# Dispatch mode: <PT|dispatch id> → worktree/branch/ticket from ~/.margie/dispatch.
# Manual mode: --branch [--repo] → the repo checkout itself.
D=""; WT=""; PT=""; TURL=""
if [ -n "$BRANCH" ]; then
  REPO="$("$DIR/resolve-repo.sh" "${REPO_ARG:-$PWD}")" || exit 1
  WT="$HOME/.margie/worktrees/$(basename "$REPO")__$(printf '%s' "$BRANCH" | tr '/ ' '--')"
  [ -d "$WT" ] || WT="$REPO"
  STATE="$MRDIR/$(basename "$REPO")__$(slug "$BRANCH")"; mkdir -p "$STATE"
elif [ -n "$REF" ] && [ "$cmd" != "view" ] && ! printf '%s' "$REF" | grep -qE '^!?[0-9]+$'; then
  D="$("$DIR/dispatch.sh" __resolve "$REF" 2>/dev/null || true)"
  [ -n "$D" ] && BRANCH_OF_D="$(jq -r '.branch // empty' "$D/impl.json" 2>/dev/null)"
  [ -z "$D" ] && { p="$MDIR/$REF"; [ -e "$p" ] && D="$(cd "$p" && pwd -P)"; }
  [ -n "$D" ] && [ -s "$D/impl.json" ] || { echo "No implemented dispatch matches '$REF', dearie — give me a PT id or --branch <b>." >&2; exit 1; }
  WT="$(jq -r .worktree "$D/impl.json")"; BRANCH="$(jq -r .branch "$D/impl.json")"
  PT="$(jq -r '.pt // empty' "$D/ticket.json" 2>/dev/null)"; TURL="$(jq -r '.url // empty' "$D/ticket.json" 2>/dev/null)"
  STATE="$D"
fi

repo_root() { git -C "$WT" rev-parse --show-toplevel 2>/dev/null; }
repo_name() { git -C "$WT" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##' | grep . || basename "$(repo_root)"; }
template_path() { local r; r="$(repo_root)"; for f in "$r/.gitlab/merge_request_templates/Default.md" "$r/.github/pull_request_template.md" "$r/.github/PULL_REQUEST_TEMPLATE.md"; do [ -f "$f" ] && { echo "$f"; return; }; done; echo ""; }

# The description: QA's draft if present, else a detached headless draft.
ensure_description() { # sets TITLE, DESCF (file), RISK; returns 1 if still drafting
  if [ -n "$DESC_FILE" ] && [ -f "$DESC_FILE" ]; then
    DESCF="$DESC_FILE"; TITLE="${TITLE_OPT:-$(head -1 "$DESC_FILE" | sed 's/^# *//')}"; RISK="$(grep -oE '/label ~"[A-Za-z]+ Risk"' "$DESCF" | head -1 | grep -oE '[A-Za-z]+ Risk' || echo "")"; return 0
  fi
  if [ -s "$STATE/qa.json" ] && jq -e '.mr.description_markdown' "$STATE/qa.json" >/dev/null 2>&1; then
    TITLE="${TITLE_OPT:-$(jq -r .mr.title "$STATE/qa.json")}"
    jq -r .mr.description_markdown "$STATE/qa.json" > "$STATE/mr-description.md"
    RISK="$(jq -r '.mr.risk_label // ""' "$STATE/qa.json")"
  elif [ -s "$STATE/mr-draft.json" ] && jq -e '.description_markdown' "$STATE/mr-draft.json" >/dev/null 2>&1; then
    TITLE="${TITLE_OPT:-$(jq -r .title "$STATE/mr-draft.json")}"
    jq -r .description_markdown "$STATE/mr-draft.json" > "$STATE/mr-description.md"
    RISK="$(jq -r '.risk_label // ""' "$STATE/mr-draft.json")"
  else
    # Kick a detached draft if one isn't already running.
    TAG="mr:$(basename "$STATE")"
    case "$("$DIR/claude-task.sh" state "$TAG")" in
      RUNNING) echo "I'm still drafting the MR description for $BRANCH, dearie — ask again in a minute."; return 1 ;;
    esac
    TPL="$(template_path)"
    P="$(cat "$DIR/prompts/mr-draft.md")"
    P="${P//'{{BRANCH}}'/$BRANCH}"; P="${P//'{{TARGET}}'/$TARGET}"
    P="${P//'{{TICKET}}'/${PT:-none}${TURL:+ — $TURL}}"
    P="${P//'{{TEMPLATE_PATH}}'/${TPL:-none}}"
    "$DIR/claude-task.sh" start "$WT" "$P" --plan --schema "$DIR/schemas/mr.schema.json" --tag "$TAG" --out "$STATE/mr-draft.json" >/dev/null
    echo "Drafting the MR description for $BRANCH from the repo template, dearie — about a minute; then say 'open the MR' again."
    return 1
  fi
  DESCF="$STATE/mr-description.md"
  # Exactly one risk quick-action at the end (the release job blocks without it).
  if ! grep -qE '^/label ~"(Low|Medium|High) Risk"' "$DESCF"; then
    [ -z "$RISK" ] && RISK="$(jq -r '.security.risk_label // "Low Risk"' "$STATE/spec.json" 2>/dev/null || echo "Low Risk")"
    printf '\n/label ~"%s"\n' "$RISK" >> "$DESCF"
  fi
  [ -z "$RISK" ] && RISK="$(grep -oE '/label ~"[A-Za-z]+ Risk"' "$DESCF" | head -1 | grep -oE '[A-Za-z]+ Risk')"
  return 0
}

case "$cmd" in
  draft)
    [ -n "$WT" ] || { echo "usage: mr.sh draft <PT|dispatch> | --branch <b> [--repo <r>]" >&2; exit 1; }
    ensure_description || exit 0
    echo "Title: $TITLE"; echo "Risk: ${RISK:-?}"; echo "Branch: $BRANCH → $TARGET"; echo "---"; cat "$DESCF" ;;
  create)
    [ -n "$WT" ] || { echo "usage: mr.sh create <PT|dispatch> | --branch <b> [--repo <r>] [--draft] [--target <b>]" >&2; exit 1; }
    [ -d "$WT" ] || { echo "The worktree for $BRANCH is gone, dearie ($WT)." >&2; exit 1; }
    # Already open?
    if [ "$FORGE" = "gitlab" ]; then EXISTING="$(cd "$WT" && glab mr view "$BRANCH" -F json 2>/dev/null | jq -r 'select(.state=="opened") | .web_url // empty')"
    else EXISTING="$(cd "$WT" && gh pr view "$BRANCH" --json url,state --jq 'select(.state=="OPEN") | .url' 2>/dev/null)"; fi
    [ -n "$EXISTING" ] && { echo "There's already an open MR for $BRANCH, dearie: $EXISTING"; exit 0; }
    if [ "${MARGIE_DESCRIBE:-0}" = "1" ]; then
      # Describe without kicking a draft: say what's known.
      if [ -s "$STATE/qa.json" ] || [ -s "$STATE/mr-draft.json" ] || [ -n "$DESC_FILE" ]; then ensure_description >/dev/null 2>&1; fi
      desc "would push branch $BRANCH and open a$([ "$DRAFT" = 1 ] && echo " draft") merge request${TITLE:+ \"$TITLE\"}${RISK:+ ($RISK)} into $TARGET in $(repo_name)${PT:+, linked to $PT}"
    fi
    ensure_description || exit 0
    N="$(git -C "$WT" rev-list --count "origin/$TARGET..HEAD" 2>/dev/null || echo "?")"
    [ "$N" = "0" ] && { echo "Branch $BRANCH has no commits beyond $TARGET yet, dearie — nothing to open."; exit 1; }
    if [ "${DRY_RUN:-0}" = "1" ]; then
      echo "DRY RUN — would run in $WT:"; echo "  git push -u origin $BRANCH"
      echo "  glab mr create --source-branch $BRANCH --target-branch $TARGET --title \"$TITLE\" --description @$DESCF --yes$([ "$DRAFT" = 1 ] && echo " --draft")"
      exit 0
    fi
    git -C "$WT" push -u origin "$BRANCH" >/dev/null 2>&1 || { echo "Couldn't push $BRANCH, dearie — check the remote/auth." >&2; exit 1; }
    if [ "$FORGE" = "gitlab" ]; then
      OUT="$(cd "$WT" && glab mr create --source-branch "$BRANCH" --target-branch "$TARGET" --title "$TITLE" --description "$(cat "$DESCF")" --yes $([ "$DRAFT" = 1 ] && echo --draft) 2>&1)"
      URL="$(printf '%s' "$OUT" | grep -oE 'https://[^ ]+/-/merge_requests/[0-9]+' | tail -1)"
    else
      OUT="$(cd "$WT" && gh pr create --head "$BRANCH" --base "$TARGET" --title "$TITLE" --body-file "$DESCF" $([ "$DRAFT" = 1 ] && echo --draft) 2>&1)"
      URL="$(printf '%s' "$OUT" | grep -oE 'https://github.com/[^ ]+/pull/[0-9]+' | tail -1)"
    fi
    [ -z "$URL" ] && { echo "Opening the MR failed, dearie: $(printf '%s' "$OUT" | tail -1 | cut -c1-160)" >&2; exit 1; }
    jq -n --arg url "$URL" --arg branch "$BRANCH" --arg title "$TITLE" --arg at "$(date -u +%FT%TZ)" '{url:$url, branch:$branch, title:$title, opened_at:$at}' > "$STATE/mr.json"
    if [ -n "$PT" ]; then
      printf 'MR opened: %s\n' "$URL" > "$STATE/mr-note.md"
      "$DIR/notion.sh" ticket append "$PT" --md "$STATE/mr-note.md" >/dev/null 2>&1 || true
      "$DIR/notion.sh" ticket status "$PT" "In Review" >/dev/null 2>&1 || true
    fi
    echo "Opened $([ "$DRAFT" = 1 ] && echo "draft ")MR \"$TITLE\" ($RISK): $URL${PT:+ — linked on $PT}" ;;
  update)
    [ -n "$REF" ] || { echo "usage: mr.sh update <PT|!n> [--title <t>] [--description-file <f>]" >&2; exit 1; }
    desc "would update MR $REF${TITLE_OPT:+ title → \"$TITLE_OPT\"}${DESC_FILE:+ and replace its description}"
    NUM="$(printf '%s' "$REF" | grep -oE '[0-9]+$')"
    [ -z "$NUM" ] && [ -n "$D" ] && NUM="$(jq -r '.url // empty' "$D/mr.json" 2>/dev/null | grep -oE '[0-9]+$')"
    [ -z "$NUM" ] && { echo "Which MR, dearie? Give me !<number> or a PT with an opened MR." >&2; exit 1; }
    R="$(cd "${WT:-$PWD}" && glab mr update "$NUM" ${TITLE_OPT:+--title "$TITLE_OPT"} ${DESC_FILE:+--description "$(cat "$DESC_FILE")"} 2>&1 | tail -1)"
    echo "Updated MR !$NUM, dearie. $R" ;;
  request-review)
    NUM="$(printf '%s' "$REF" | grep -oE '[0-9]+$')"
    [ -z "$NUM" ] && [ -n "$D" ] && NUM="$(jq -r '.iid // empty' "$D/mr.json" 2>/dev/null)"
    [ -z "$NUM" ] && { echo "Which MR, dearie? Give me !<number>." >&2; exit 1; }
    cd "${WT:-${REPO_ARG:-$PWD}}" || exit 1
    P="$(glab api "projects/:id/merge_requests/$NUM/pipelines" 2>/dev/null | jq -r '.[0].id // empty')"
    [ -z "$P" ] && { echo "No pipeline on !$NUM yet, dearie." >&2; exit 1; }
    PLAYED=""; SKIPPED=""
    for DS in $(glab api "projects/:id/pipelines/$P/bridges" 2>/dev/null | jq -r '.[] | select(.name|test("review")) | .downstream_pipeline.id // empty'); do
      for J in $(glab api "projects/:id/pipelines/$DS/jobs?per_page=50" 2>/dev/null | jq -r '.[] | select(.name|test(":request$")) | "\(.id):\(.name):\(.status)"'); do
        jid="${J%%:*}"; rest="${J#*:}"; jname="${rest%%:*}"; jst="${rest##*:}"
        if [ "$jst" = manual ]; then glab api -X POST "projects/:id/jobs/$jid/play" >/dev/null 2>&1 && PLAYED="$PLAYED $jname"; else SKIPPED="$SKIPPED $jname($jst)"; fi
      done
    done
    [ -n "$PLAYED" ] && echo "Requested the review bots on !$NUM (pipeline $P):$PLAYED — their comments land as review threads in a few minutes, dearie."
    [ -z "$PLAYED" ] && echo "Nothing to play on !$NUM, dearie —${SKIPPED:- no review jobs found}." ;;
  check|merge)
    NUM="$(printf '%s' "$REF" | grep -oE '[0-9]+$')"
    [ -z "$NUM" ] && [ -n "$D" ] && NUM="$(jq -r '.iid // (.url // "" | capture("(?<n>[0-9]+)$").n) // empty' "$D/mr.json" 2>/dev/null)"
    if [ -z "$NUM" ] && [ -n "${BRANCH_OF_D:-}" ]; then NUM="$(cd "${WT:-$PWD}" && glab mr list --source-branch "$BRANCH_OF_D" -F json 2>/dev/null | jq -r '.[0].iid // empty')"; fi
    [ -z "$NUM" ] && { echo "Which MR, dearie? Give me !<number> or a PT with an opened MR." >&2; exit 1; }
    cd "${WT:-${REPO_ARG:-$PWD}}" || exit 1
    if [ "$cmd" = check ]; then
      V="$(glab mr view "$NUM" -F json 2>/dev/null)"; [ -z "$V" ] && { echo "Couldn't read MR !$NUM, dearie." >&2; exit 1; }
      UNRES="$(glab api "projects/:id/merge_requests/$NUM/discussions?per_page=100" 2>/dev/null | jq '[.[] | select(.notes[0].resolvable==true and (.notes[0].resolved==false))] | length' 2>/dev/null || echo 0)"
      APPR="$(glab api "projects/:id/merge_requests/$NUM/approvals" 2>/dev/null | jq -c '{approved, approvals_left}' 2>/dev/null || echo '{}')"
      PIPE="$(glab api "projects/:id/merge_requests/$NUM/pipelines" 2>/dev/null | jq -c '.[0] // {}' 2>/dev/null || echo '{}')"
      printf '%s' "$V" | jq -c --argjson unres "${UNRES:-0}" --argjson appr "$APPR" --argjson pipe "$PIPE" \
        '{iid, title, state, merge_status: (.detailed_merge_status // .merge_status), conflicts: (.has_conflicts // false), sha, url: .web_url,
          pipeline: ($pipe.status // .head_pipeline.status // "none"), pipeline_id: ($pipe.id // null), pipeline_url: ($pipe.web_url // null),
          unresolved: $unres, approved: ($appr.approved // true), approvals_left: ($appr.approvals_left // 0)}'
    else
      T="$(glab mr view "$NUM" -F json 2>/dev/null | jq -r '.title // "?"')"
      desc "would merge MR !$NUM (\"$T\") into $TARGET and delete its source branch"
      OUT="$(glab mr merge "$NUM" --yes --remove-source-branch 2>&1 | tail -2 | tr '\n' ' ')"
      case "$OUT" in *rror*|*failed*|*cannot*|*Cannot*) echo "Merge of !$NUM didn't go through, dearie: $OUT"; exit 1 ;; esac
      echo "Merged MR !$NUM (\"$T\") into $TARGET, dearie. $OUT"
    fi ;;
  view)
    "$DIR/forge.sh" mr "$(printf '%s' "$REF" | grep -oE '[0-9]+$')" "${1:-}" ;;
  *)
    echo "usage: mr.sh draft|create <PT|dispatch|--branch b [--repo r]> [--draft] [--target b] | update <PT|!n> [--title t] [--description-file f] | view <!n> [repo] | check <PT|!n> | merge <PT|!n> | request-review <PT|!n>" >&2
    exit 1 ;;
esac
